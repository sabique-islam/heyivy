import AppKit
import IvyCore
import IvyOverlay
import QuartzCore

/// One screen as Claude will see it.
public struct LessonScreen {
    /// The image sent to Claude. Mark positions are in its pixels.
    public var screenshotJPEGData: Data
    /// The full-resolution capture, for text recognition, which finds more words on it.
    public var fullResolutionImage: CGImage
    /// Maps the sent image's pixels to screen points.
    public var geometry: CapturedScreenGeometry

    public init(screenshotJPEGData: Data, fullResolutionImage: CGImage, geometry: CapturedScreenGeometry) {
        self.screenshotJPEGData = screenshotJPEGData
        self.fullResolutionImage = fullResolutionImage
        self.geometry = geometry
    }
}

/// What the overlay needs to draw one mark.
public struct MarkDrawing: Sendable, Equatable {
    public var kind: MarkKind
    public var globalRect: CGRect
    public var labelText: String?
}

/// What happened to one mark, for the lesson log. It holds no words from the screen.
public struct MarkOutcome {
    public var markIndex: Int
    public var kind: MarkKind
    public var outcome: String
    public var shownAtHeardSeconds: Double?
    public var wordStartSeconds: Double?
}

/// Runs one lesson from question to the last mark: Claude's script streams in, its speech
/// goes to the voice, its marks are found on screen, and each mark is drawn as its words
/// are heard. Cancelling stops all of it at once.
@MainActor
public final class LessonEngine {
    public var onFirstAudioHeard: (() -> Void)?
    public var onFinished: (() -> Void)?
    public var onFailed: ((LessonFailure) -> Void)?

    public private(set) var spokenText = ""
    public private(set) var markOutcomes: [MarkOutcome] = []
    /// Every mark Claude asked for, with the screen text it named. For labs checking their
    /// own screens. The app must not log these, since they can hold what's on the user's screen.
    public private(set) var requestedMarks: [MarkRequest] = []
    public private(set) var resolvedBoxesInImagePixels: [Int: CGRect] = [:]
    public let timingLog: LessonTimingLog

    private let workerBaseURL: String
    private let deviceToken: String
    private let markOverlay: MarkOverlayController
    private let outputDevice: AudioDevice?
    /// Made when the lesson runs, not when the key goes down. See `VoiceStream.attach`.
    private var speechPlayer: StreamingSpeechPlayer?
    private let voiceStream: VoiceStream
    private var scriptParser = LessonScriptParser()
    private var markTimeline = MarkTimeline<MarkDrawing>(leadSeconds: 0.08)
    private var scriptTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?

    private var screen: LessonScreen?
    private var recognizedWords: [RecognizedWord]?
    private var marksWaitingForTextRecognition: [MarkRequest] = []
    private var hasHeardFirstAudio = false
    private var hasFinished = false
    private var isCancelled = false

    /// Call when the key goes down, so the voice connection is ready by the time the script is.
    /// It only opens the network connection. Audio output starts in `run`, once the mic is done.
    public init(workerBaseURL: String, deviceToken: String, markOverlay: MarkOverlayController, outputDevice: AudioDevice? = nil, timingLog: LessonTimingLog = LessonTimingLog()) {
        self.workerBaseURL = workerBaseURL
        self.deviceToken = deviceToken
        self.markOverlay = markOverlay
        self.outputDevice = outputDevice
        self.timingLog = timingLog
        voiceStream = VoiceStream(workerBaseURL: workerBaseURL, deviceToken: deviceToken)
        voiceStream.onFirstAudioReceived = { [weak self] in self?.timingLog.record("first audio received") }
        voiceStream.onFailed = { [weak self] failure in self?.fail(with: failure) }
        voiceStream.open()
    }

    public func run(question: String, screen: LessonScreen, history: [LessonExchange]) {
        self.screen = screen

        let imageSize = screen.geometry.imagePixelSize
        let systemPrompt = LessonPrompt.systemPrompt(imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height))
        let screenshotLabel = "The user's screen, \(Int(imageSize.width))x\(Int(imageSize.height)) pixels."
        // Making the stream sends the request at once, off the main thread. It goes first
        // because starting audio output below blocks for about 0.3 s, and Claude's answer is
        // what everything else waits for.
        let scriptStream = ClaudeScriptStream.streamScript(
            workerBaseURL: workerBaseURL, deviceToken: deviceToken, systemPrompt: systemPrompt,
            screenshotJPEGData: screen.screenshotJPEGData, screenshotLabel: screenshotLabel, question: question, history: history
        )
        timingLog.record("question sent")

        startTextRecognition(on: screen)
        startSpeechPlayer(attemptsRemaining: Self.speechPlayerStartAttempts)
        startDisplayLink()

        scriptTask = Task { [weak self] in
            guard let self else { return }
            var hasReceivedText = false
            do {
                for try await scriptText in scriptStream {
                    if !hasReceivedText {
                        hasReceivedText = true
                        timingLog.record("first script text")
                    }
                    handle(scriptParser.consume(scriptText))
                }
                handle(scriptParser.finish())
                timingLog.record("script finished")
                voiceStream.finishText()
            } catch let lessonFailure as LessonFailureError {
                fail(with: lessonFailure.failure)
            } catch {
                if !isCancelled { fail(with: .answerFailed) }
            }
        }
    }

    // A Bluetooth headset takes a moment to switch back from headset mode after the mic stops,
    // and audio output can't start until it has. Claude takes about 2 seconds to start
    // speaking, so a few short retries cost nothing, and early audio waits in the voice stream.
    private static let speechPlayerStartAttempts = 6
    private static let speechPlayerRetryDelaySeconds = 0.3

    private func startSpeechPlayer(attemptsRemaining: Int) {
        guard !isCancelled, !hasFinished else { return }
        do {
            let newSpeechPlayer = try StreamingSpeechPlayer(outputDevice: outputDevice)
            newSpeechPlayer.onPlaybackFailed = { [weak self] in self?.fail(with: .voiceFailed) }
            speechPlayer = newSpeechPlayer
            voiceStream.attach(speechPlayer: newSpeechPlayer)
            timingLog.record("audio output started")
        } catch {
            guard attemptsRemaining > 1 else {
                fail(with: .voiceFailed)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.speechPlayerRetryDelaySeconds) { [weak self] in
                self?.startSpeechPlayer(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    /// Stops speech at once, then everything else. Marks clear immediately.
    public func cancel() {
        isCancelled = true
        speechPlayer?.stop()
        voiceStream.close()
        scriptTask?.cancel()
        stopDisplayLink()
        markOverlay.clearAll()
    }

    private func handle(_ parserOutputs: [ScriptParserOutput]) {
        for parserOutput in parserOutputs {
            switch parserOutput {
            case .speech(let speechText):
                if spokenText.isEmpty { timingLog.record("first speech sent to voice") }
                spokenText += speechText
                voiceStream.send(speechText: speechText)
            case .mark(let markRequest):
                requestedMarks.append(markRequest)
                // Only text marks need text recognition. Others are placed by position.
                let needsTextRecognition: Bool
                if case .visibleText = markRequest.target { needsTextRecognition = true } else { needsTextRecognition = false }
                if needsTextRecognition && recognizedWords == nil {
                    marksWaitingForTextRecognition.append(markRequest)
                } else {
                    resolve(markRequest)
                }
            }
        }
    }

    private func startTextRecognition(on screen: LessonScreen) {
        let fullResolutionImage = screen.fullResolutionImage
        let sentImageSize = screen.geometry.imagePixelSize
        // Recognition takes a few hundred milliseconds, so it runs off the main thread while
        // Claude is still thinking.
        Task.detached(priority: .userInitiated) { [weak self] in
            let words = (try? ScreenTextRecognizer.recognizeWords(in: fullResolutionImage, reportedInPixelSize: sentImageSize)) ?? []
            await self?.textRecognitionFinished(with: words)
        }
    }

    private func textRecognitionFinished(with words: [RecognizedWord]) {
        timingLog.record("text recognition done (\(words.count) words)")
        recognizedWords = words
        let waitingMarks = marksWaitingForTextRecognition
        marksWaitingForTextRecognition = []
        waitingMarks.forEach(resolve)
    }

    private func resolve(_ markRequest: MarkRequest) {
        guard let screen else { return }
        let resolution = TargetResolver.resolve(mark: markRequest, recognizedWords: recognizedWords, imagePixelSize: screen.geometry.imagePixelSize)
        var outcome = MarkOutcome(markIndex: markRequest.markIndex, kind: markRequest.kind, outcome: "", shownAtHeardSeconds: nil, wordStartSeconds: nil)
        let targetBox: CGRect
        switch resolution {
        case .drawOnText(let box, let matchQuality):
            outcome.outcome = matchQuality == .exact ? "exact text match" : "close text match"
            targetBox = box
        case .drawAroundPosition(let box):
            outcome.outcome = "drawn at position"
            targetBox = box
        case .dropped(let reason):
            outcome.outcome = "dropped: \(reason)"
            markOutcomes.append(outcome)
            // Why, and what kind of target, but never the words, which come from the screen.
            timingLog.record("mark \(markRequest.markIndex) dropped (\(reason), \(Self.targetDescription(markRequest.target)))")
            return
        }
        markOutcomes.append(outcome)
        resolvedBoxesInImagePixels[markRequest.markIndex] = targetBox
        var labelText: String?
        if case .labelText(let text) = markRequest.target { labelText = text }
        markTimeline.addMark(
            markIndex: markRequest.markIndex,
            spokenCharacterOffset: markRequest.spokenCharacterOffset,
            spokenWords: markRequest.spokenWords,
            payload: MarkDrawing(kind: markRequest.kind, globalRect: screen.geometry.globalRect(fromImagePixelRect: targetBox), labelText: labelText)
        )
    }

    private static func targetDescription(_ target: MarkTarget) -> String {
        switch target {
        case .visibleText(let words): return "text target of \(words.count) word\(words.count == 1 ? "" : "s")"
        case .nonText: return "non-text target"
        case .labelText: return "label"
        }
    }

    private func screenWillRefresh(displayHostSeconds: Double) {
        guard !isCancelled else { return }
        guard let speechPlayer else { return }
        let heardContentSeconds = speechPlayer.update(predictingHeardAtHostSeconds: displayHostSeconds)
        if heardContentSeconds > 0 && !hasHeardFirstAudio {
            hasHeardFirstAudio = true
            timingLog.record("first audio heard")
            onFirstAudioHeard?()
        }

        let timelineUpdate = markTimeline.update(heardContentSeconds: heardContentSeconds, speechTimeline: voiceStream.speechTimeline)
        for markToShow in timelineUpdate.marksToShow {
            markOverlay.show(markID: markToShow.markIndex, kind: markToShow.payload.kind, globalRect: markToShow.payload.globalRect, labelText: markToShow.payload.labelText)
            timingLog.record("mark \(markToShow.markIndex) shown")
            if let outcomeIndex = markOutcomes.firstIndex(where: { $0.markIndex == markToShow.markIndex }) {
                markOutcomes[outcomeIndex].shownAtHeardSeconds = heardContentSeconds
                markOutcomes[outcomeIndex].wordStartSeconds = markToShow.startSeconds
            }
        }
        for fadedMarkIndex in timelineUpdate.marksToFade { markOverlay.fade(markID: fadedMarkIndex) }
        for lateMarkIndex in timelineUpdate.marksDroppedAsLate {
            timingLog.record("mark \(lateMarkIndex) dropped (too late for its words)")
            if let outcomeIndex = markOutcomes.firstIndex(where: { $0.markIndex == lateMarkIndex }) {
                markOutcomes[outcomeIndex].outcome = "dropped: too late for its words"
            }
        }

        if speechPlayer.hasFinishedPlaying && voiceStream.hasReceivedFinalMessage && !hasFinished {
            hasFinished = true
            timingLog.record("speech finished")
            stopDisplayLink()
            // Marks stay a few seconds after the lesson, then fade.
            markOverlay.fadeAll(afterSeconds: 3)
            onFinished?()
        }
    }

    private func fail(with failure: LessonFailure) {
        guard !hasFinished, !isCancelled else { return }
        timingLog.record("failed: \(failure)")
        hasFinished = true
        stopDisplayLink()
        onFailed?(failure)
    }

    private func startDisplayLink() {
        let target = DisplayLinkTarget { [weak self] link in
            MainActor.assumeIsolated { self?.screenWillRefresh(displayHostSeconds: link.targetTimestamp) }
        }
        guard let link = (NSScreen.main ?? NSScreen.screens.first)?.displayLink(target: target, selector: #selector(DisplayLinkTarget.screenWillRefresh(_:))) else { return }
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayLinkTarget = target
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }
}

/// CADisplayLink needs an Objective-C target, so this forwards each frame to a closure.
private final class DisplayLinkTarget: NSObject {
    private let onFrame: (CADisplayLink) -> Void
    init(onFrame: @escaping (CADisplayLink) -> Void) { self.onFrame = onFrame }
    @objc func screenWillRefresh(_ link: CADisplayLink) { onFrame(link) }
}
