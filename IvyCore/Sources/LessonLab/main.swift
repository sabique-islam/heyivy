import AppKit
import IvyCore
import IvyLesson
import IvyOverlay

// LessonLab: one real lesson, end to end (drawing plan, D4). It opens a window of code with
// a bug, asks Claude a typed question about it through the Worker, speaks the answer, and
// draws marks as the words are heard. Then it writes a timing log and what happened to
// each mark.
//
// The screenshot is drawn from the lab's own window rather than captured from the screen,
// so the lab needs no Screen Recording permission. Everything after that is the real thing.
//
//   --question TEXT   What to ask. Default: why the average is wrong.
//   --result PATH     Where to write the JSON result.
//   --force FAILURE   Make one thing fail, and report what the user would be told (D5):
//                     not-authorized, offline, voice-at-start, or voice-midway.
//   --interrupts N    Start N lessons and cancel each at a random moment, some while
//                     thinking and some while speaking, and time how fast each goes quiet.
//
// Run it with scripts/lesson-lab.sh. Each run costs a few cents, and --interrupts costs
// about a cent per lesson.

let codeWithABug = """
def average_scores(scores):
    total = 0
    for index in range(len(scores) - 1):
        total += scores[index]
    return total / len(scores)


print(average_scores([90, 80, 70]))   # prints 56.67, not 80
"""

struct LabOptions {
    var question = "Why does this print 56.67 instead of 80?"
    var resultPath = FileManager.default.temporaryDirectory.appendingPathComponent("lesson-lab-result.json").path
    var forcedFailure: String?
    var interruptCount = 0

    init(arguments: [String]) {
        var argumentIndex = 1
        while argumentIndex < arguments.count {
            let nextValue = argumentIndex + 1 < arguments.count ? arguments[argumentIndex + 1] : ""
            switch arguments[argumentIndex] {
            case "--question": question = nextValue; argumentIndex += 1
            case "--result": resultPath = nextValue; argumentIndex += 1
            case "--force": forcedFailure = nextValue; argumentIndex += 1
            case "--interrupts": interruptCount = Int(nextValue) ?? 20; argumentIndex += 1
            default: break
            }
            argumentIndex += 1
        }
    }
}

/// Reads the token the way scripts/mint-device-token.mjs stored it, through the `security`
/// tool that created the Keychain item, which avoids a permission prompt.
func readWorkerDeviceToken() -> String? {
    let securityProcess = Process()
    securityProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    securityProcess.arguments = ["find-generic-password", "-s", "me.ivyx.ivy.worker-device-token", "-a", "device", "-w"]
    let outputPipe = Pipe()
    securityProcess.standardOutput = outputPipe
    securityProcess.standardError = FileHandle.nullDevice
    do { try securityProcess.run() } catch { return nil }
    securityProcess.waitUntilExit()
    guard securityProcess.terminationStatus == 0 else { return nil }
    return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
final class LabController: NSObject, NSApplicationDelegate {
    private let options = LabOptions(arguments: CommandLine.arguments)
    private let markOverlay = MarkOverlayController()
    private var codeWindow: NSWindow!
    private var lessonEngine: LessonEngine?
    private var result: [String: Any] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return finish(withError: "No screen.") }

        let codeView = NSTextView(frame: CGRect(x: 0, y: 0, width: 900, height: 360))
        codeView.string = codeWithABug
        codeView.font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        codeView.isEditable = false
        codeView.textContainerInset = NSSize(width: 24, height: 24)
        codeView.backgroundColor = NSColor(white: 0.12, alpha: 1)
        codeView.textColor = NSColor(white: 0.92, alpha: 1)
        codeWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        codeWindow.title = "scores.py"
        codeWindow.contentView = codeView
        codeWindow.center()
        codeWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard let deviceToken = readWorkerDeviceToken() else {
            return finish(withError: "No device token in the Keychain. Run scripts/mint-device-token.mjs.")
        }

        // Each lab build is a new app to text recognition, and its first use can take most of a
        // minute. The app warms it at launch, so the lab waits for that here and reports it.
        Task.detached(priority: .userInitiated) {
            let warmUpSeconds = ScreenTextRecognizer.warmUp()
            await MainActor.run {
                self.result["textRecognitionWarmUpMs"] = Int((warmUpSeconds * 1000).rounded())
                self.startLesson(on: screen, deviceToken: deviceToken)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (options.interruptCount > 0 ? 600 : 150)) { [weak self] in self?.finish(withError: "Timed out.") }
    }

    private static let workerBaseURL = "https://secrets.worker.ivy.ivyx.me"
    /// The same state machine the app uses, fed what the engine reports, so the lab can say
    /// what the user would see.
    private var lessonStateMachine = LessonStateMachine()
    private var messagesShown: [String] = []
    private var failuresReported: [String] = []
    private var answerWasShownAsText = false

    private func startLesson(on screen: NSScreen, deviceToken: String) {
        if options.interruptCount > 0 {
            runInterrupts(on: screen, deviceToken: deviceToken, lessonsLeft: options.interruptCount)
            return
        }
        var workerBaseURL = Self.workerBaseURL
        var lessonDeviceToken = deviceToken
        switch options.forcedFailure {
        case "not-authorized": lessonDeviceToken = "ivy1.not-a-real-device.0.not-a-real-signature"
        // .invalid never resolves, which is what being offline looks like to the app.
        case "offline": workerBaseURL = "https://ivy-offline-check.invalid"
        default: break
        }
        let timingLog = LessonTimingLog()
        let engine = LessonEngine(workerBaseURL: workerBaseURL, deviceToken: lessonDeviceToken, markOverlay: markOverlay, timingLog: timingLog, watchesScreenForChanges: false)
        switch options.forcedFailure {
        case "voice-at-start": engine.voiceFailureForTesting = .atStart
        case "voice-midway": engine.voiceFailureForTesting = .afterFirstAudio(seconds: 1.5)
        default: break
        }
        lessonEngine = engine
        guard let lessonScreen = renderScreenshot(of: screen) else { return finish(withError: "Couldn't draw the screenshot.") }
        timingLog.record("screen captured")

        _ = lessonStateMachine.handle(.keyPressed)
        let lessonID = lessonStateMachine.currentLessonID
        _ = lessonStateMachine.handle(.keyReleased(transcriptIsEmpty: false))
        engine.onFirstAudioHeard = { [weak self] in _ = self?.lessonStateMachine.handle(.firstAudioPlayed(lessonID)) }
        engine.onFinished = { [weak self] in
            _ = self?.lessonStateMachine.handle(.speechFinished(lessonID))
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.finish(withError: nil) }
        }
        engine.onScriptFinished = { [weak self] _ in
            guard let self, self.answerWasShownAsText else { return }
            // The answer is all there as text, which is the end of a lesson whose voice failed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finish(withError: nil) }
        }
        engine.onFailed = { [weak self] failure in
            guard let self else { return }
            self.failuresReported.append("\(failure)")
            let effects = self.lessonStateMachine.handle(.failed(lessonID, failure))
            for effect in effects {
                switch effect {
                case .showMessage(let userMessage): self.messagesShown.append(userMessage.text)
                case .showAnswerAsText:
                    self.answerWasShownAsText = true
                    // The voice can fail after the whole script arrived.
                    if self.lessonEngine?.hasScriptFinished == true {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finish(withError: nil) }
                    }
                case .stopAudio: self.lessonEngine?.stopAudio()
                case .stopNewMarks: self.lessonEngine?.stopNewMarks()
                case .cancelLessonWork: self.lessonEngine?.cancel()
                case .clearMarks: self.markOverlay.clearAll()
                default: break
                }
            }
            // A failure that stops everything ends the run. After a voice failure, the
            // answer keeps coming as text, so the run waits for the script to finish.
            if effects.contains(.cancelLessonWork(lessonID)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finish(withError: nil) }
            }
        }
        engine.run(question: options.question, screen: lessonScreen, history: [])
    }

    private var interruptReports: [[String: Any]] = []

    /// Each lesson is cancelled after a random wait. Cancelling must stop speech and clear
    /// marks at once, and nothing from a cancelled lesson may happen afterwards.
    private func runInterrupts(on screen: NSScreen, deviceToken: String, lessonsLeft: Int) {
        guard lessonsLeft > 0 else {
            let cancelMilliseconds = interruptReports.compactMap { $0["cancelMs"] as? Double }
            let outputLatencyMilliseconds = ((AudioDevices.defaultOutputDeviceID().map { AudioDevices.latencySeconds(of: $0, isInput: false) } ?? 0) * 1000).rounded()
            result["interrupts"] = interruptReports
            result["interruptSummary"] = [
                "lessons": interruptReports.count,
                "cancelledWhileSpeaking": interruptReports.filter { $0["wasSpeaking"] as? Bool == true }.count,
                "slowestCancelMs": cancelMilliseconds.max() ?? -1,
                "outputLatencyMs": outputLatencyMilliseconds,
                "slowestSilenceMs": (cancelMilliseconds.max() ?? 0) + outputLatencyMilliseconds,
                "marksLeftAfterAnyCancel": interruptReports.compactMap { $0["marksLeftAfterCancel"] as? Int }.max() ?? 0,
                "callbacksAfterCancel": interruptReports.compactMap { $0["callbacksAfterCancel"] as? Int }.reduce(0, +),
            ] as [String: Any]
            lessonEngine = nil
            return finish(withError: nil)
        }
        guard let lessonScreen = renderScreenshot(of: screen) else { return finish(withError: "Couldn't draw the screenshot.") }
        let engine = LessonEngine(workerBaseURL: Self.workerBaseURL, deviceToken: deviceToken, markOverlay: markOverlay, timingLog: LessonTimingLog(), watchesScreenForChanges: false)
        var hasBeenCancelled = false
        var callbacksAfterCancel = 0
        engine.onFirstAudioHeard = { if hasBeenCancelled { callbacksAfterCancel += 1 } }
        engine.onFinished = { if hasBeenCancelled { callbacksAfterCancel += 1 } }
        engine.onFailed = { _ in if hasBeenCancelled { callbacksAfterCancel += 1 } }
        engine.run(question: options.question, screen: lessonScreen, history: [])

        // Claude's first audio takes about 3 seconds, so this spread cancels roughly half
        // the lessons while thinking and half while speaking.
        let secondsBeforeCancel = Double.random(in: 0.3...6.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsBeforeCancel) {
            let wasSpeaking = engine.isSpeaking
            let marksBeforeCancel = self.markOverlay.shownMarkCount
            let cancelStartSeconds = ProcessInfo.processInfo.systemUptime
            engine.cancel()
            let cancelMilliseconds = ((ProcessInfo.processInfo.systemUptime - cancelStartSeconds) * 1000 * 10).rounded() / 10
            hasBeenCancelled = true
            let marksLeftAfterCancel = self.markOverlay.shownMarkCount
            // Waits to see whether anything from the cancelled lesson still happens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.interruptReports.append([
                    "cancelledAfterSeconds": (secondsBeforeCancel * 10).rounded() / 10,
                    "wasSpeaking": wasSpeaking,
                    "marksBeforeCancel": marksBeforeCancel,
                    "cancelMs": cancelMilliseconds,
                    "marksLeftAfterCancel": marksLeftAfterCancel,
                    "callbacksAfterCancel": callbacksAfterCancel,
                ])
                self.runInterrupts(on: screen, deviceToken: deviceToken, lessonsLeft: lessonsLeft - 1)
            }
        }
    }

    /// A full-screen image with the code window where it really is, like a capture, at full
    /// resolution for text recognition and shrunk to 1280 pixels wide for Claude, as the app does.
    private func renderScreenshot(of screen: NSScreen) -> LessonScreen? {
        guard let contentView = codeWindow.contentView,
              let windowBitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return nil }
        contentView.cacheDisplay(in: contentView.bounds, to: windowBitmap)
        guard let windowImage = windowBitmap.cgImage else { return nil }

        let scale = screen.backingScaleFactor
        let fullWidth = Int(screen.frame.width * scale)
        let fullHeight = Int(screen.frame.height * scale)
        guard let fullContext = CGContext(data: nil, width: fullWidth, height: fullHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        fullContext.setFillColor(CGColor(srgbRed: 0.35, green: 0.38, blue: 0.45, alpha: 1))
        fullContext.fill(CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
        // Both are bottom-left origin, so the window's frame on screen maps straight across.
        let contentFrameOnScreen = codeWindow.convertToScreen(contentView.frame)
        let drawRect = CGRect(x: (contentFrameOnScreen.minX - screen.frame.minX) * scale, y: (contentFrameOnScreen.minY - screen.frame.minY) * scale, width: contentFrameOnScreen.width * scale, height: contentFrameOnScreen.height * scale)
        fullContext.draw(windowImage, in: drawRect)
        guard let fullResolutionImage = fullContext.makeImage() else { return nil }

        let sentWidth = 1280
        let sentHeight = Int((Double(sentWidth) * screen.frame.height / screen.frame.width).rounded())
        guard let sentContext = CGContext(data: nil, width: sentWidth, height: sentHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        sentContext.interpolationQuality = .high
        sentContext.draw(fullResolutionImage, in: CGRect(x: 0, y: 0, width: sentWidth, height: sentHeight))
        guard let sentImage = sentContext.makeImage(),
              let jpegData = NSBitmapImageRep(cgImage: sentImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }

        return LessonScreen(
            screenshotJPEGData: jpegData,
            fullResolutionImage: fullResolutionImage,
            geometry: CapturedScreenGeometry(imagePixelSize: CGSize(width: sentWidth, height: sentHeight), screenFrameInGlobalPoints: screen.frame)
        )
    }

    private func finish(withError errorMessage: String?) {
        if let errorMessage { result["error"] = errorMessage }
        if let forcedFailure = options.forcedFailure {
            result["forcedFailure"] = forcedFailure
            result["failuresReported"] = failuresReported
            result["messagesShown"] = messagesShown
            result["answerShownAsText"] = answerWasShownAsText
        }
        if let lessonEngine {
            result["question"] = options.question
            result["spokenText"] = lessonEngine.spokenText
            result["timingsMs"] = lessonEngine.timingLog.stageTimesMilliseconds.map { ["stage": $0.stage, "ms": $0.milliseconds] }
            result["marks"] = lessonEngine.markOutcomes.map { markOutcome -> [String: Any] in
                var markReport: [String: Any] = ["mark": markOutcome.markIndex, "kind": markOutcome.kind.rawValue, "outcome": markOutcome.outcome]
                // The lab's screen is its own code, so it can say what each mark pointed at.
                if let markRequest = lessonEngine.requestedMarks.first(where: { $0.markIndex == markOutcome.markIndex }) {
                    markReport["spokenWords"] = markRequest.spokenWords
                    markReport["target"] = "\(markRequest.target)"
                }
                if let box = lessonEngine.resolvedBoxesInImagePixels[markOutcome.markIndex] {
                    markReport["boxInScreenshotPixels"] = "\(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))x\(Int(box.height))"
                }
                if let shownAt = markOutcome.shownAtHeardSeconds, let wordStart = markOutcome.wordStartSeconds {
                    // Negative means the mark appeared before its word, as the lead intends.
                    markReport["shownMsRelativeToItsWord"] = Int(((shownAt - wordStart) * 1000).rounded())
                }
                return markReport
            }
            print(lessonEngine.timingLog.summaryLine)
            lessonEngine.cancel()
        }
        if let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: options.resultPath, contents: resultData)
        }
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let labController = LabController()
    application.delegate = labController
    application.run()
}
