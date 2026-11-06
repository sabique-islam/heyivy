import AppKit
import AVFoundation
import IvyCore
import IvyLesson
import QuartzCore

// VoiceSyncLab: checks that marks land on their words (drawing plan, D1).
//
//   --mode clicks   Plays clicks, flashes the screen on each, and measures the error with the mic.
//   --mode speech   Speaks a real script through the Worker's /voice and puts a dot on each word.
//   --output speakers|bluetooth|default   Which device plays the audio. Default: the system's.
//   --stall         In speech mode, holds the network stream back once, to force a stall.
//   --result PATH   Where to write the JSON result.
//
// Run it with scripts/voice-sync-lab.sh, which wraps it in an app so macOS can grant the mic.

struct LabOptions {
    var mode = "clicks"
    var outputChoice = "default"
    var forceStallInSpeechMode = false
    var resultPath = FileManager.default.temporaryDirectory.appendingPathComponent("voice-sync-lab-result.json").path

    init(arguments: [String]) {
        var argumentIndex = 1
        while argumentIndex < arguments.count {
            let argument = arguments[argumentIndex]
            let nextValue = argumentIndex + 1 < arguments.count ? arguments[argumentIndex + 1] : ""
            switch argument {
            case "--mode": mode = nextValue; argumentIndex += 1
            case "--output": outputChoice = nextValue; argumentIndex += 1
            case "--result": resultPath = nextValue; argumentIndex += 1
            case "--stall": forceStallInSpeechMode = true
            default: break
            }
            argumentIndex += 1
        }
    }
}

let workerBaseURL = "https://secrets.worker.ivy.ivyx.me"

// A short explanation in the shape of a real lesson, with numbers and code words in it.
let lessonScript = "Look at line twelve. The loop starts at zero, so the last index is the length minus one. That's why the final item in your list was skipped, and changing the less-than to less-than-or-equal fixes it."

final class LabController: NSObject, NSApplicationDelegate {
    private let options = LabOptions(arguments: CommandLine.arguments)
    private var window: NSWindow!
    private var displayLink: CADisplayLink?
    private var speechPlayer: StreamingSpeechPlayer?
    private var wordScheduler = WordCueScheduler(leadSeconds: 0)
    private var labStartHostSeconds = currentHostSeconds()
    private var finishedAtHostSeconds: Double?
    private var result: [String: Any] = [:]

    // Click mode
    private var networkFeed: SimulatedNetworkFeed?
    private var microphoneRecorder: MicrophoneClickRecorder?
    private var flashLayer = CALayer()
    private var flashOffAtHostSeconds = 0.0
    private var flashHostTimesByClickIndex: [Int: Double] = [:]

    // Speech mode
    private var voiceConnection: VoiceConnection?
    private var speechTimeline = SpeechTimeline()
    private var receivedAudioSeconds = 0.0
    private var heldMessagesDuringForcedStall: [[String: Any]]?
    private var forcedStallHasHappened = false
    private var forcedStallStartedHostSeconds = 0.0
    private var stallsBeforeForcedStall = 0
    private var playerPausedDuringForcedStallAtHostSeconds: Double?
    private var connectionHasClosed = false
    private var firstAudioReceivedHostSeconds: Double?
    private var streamFinalReceived = false
    private var firstTextSentHostSeconds: Double?
    private var firstAudioHeardHostSeconds: Double?
    private var textView: NSTextView!
    private var wordDotLayer = CALayer()
    private var sentWordRanges: [NSRange] = []
    private var cuedWordCount = 0
    private var voiceCloseReason: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        result["mode"] = options.mode
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Ivy voice sync lab: \(options.mode)"
        window.center()
        window.contentView?.wantsLayer = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        do {
            speechPlayer = try StreamingSpeechPlayer(outputDevice: AudioDevices.outputDevice(named: options.outputChoice))
        } catch {
            finish(withError: "Couldn't start audio output: \(error.localizedDescription)")
            return
        }

        if options.mode == "devices" {
            result["devices"] = AudioDevices.allDevices().map { device -> [String: Any] in
                var description: [String: Any] = ["name": device.name, "builtIn": device.isBuiltIn, "bluetooth": device.isBluetooth]
                if device.outputChannelCount > 0 { description["outputLatencyMs"] = Int((AudioDevices.latencySeconds(of: device.deviceID, isInput: false) * 1000).rounded()) }
                if device.inputChannelCount > 0 { description["inputLatencyMs"] = Int((AudioDevices.latencySeconds(of: device.deviceID, isInput: true) * 1000).rounded()) }
                return description
            }
            result["engineReportedOutputLatencyMsForThisRun"] = Int(((speechPlayer?.engineReportedOutputLatencySeconds ?? 0) * 1000).rounded())
            finish(withError: nil)
            return
        } else if options.mode == "speech" {
            startSpeechMode()
        } else {
            startClickMode()
        }

        let link = window.contentView!.displayLink(target: self, selector: #selector(screenWillRefresh(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: - Click mode

    private func startClickMode() {
        let contentView = window.contentView!
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        flashLayer.frame = contentView.bounds.insetBy(dx: 40, dy: 40)
        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        contentView.layer?.addSublayer(flashLayer)
        wordScheduler = WordCueScheduler(leadSeconds: 0)

        AVCaptureDevice.requestAccess(for: .audio) { microphoneAllowed in
            DispatchQueue.main.async {
                guard microphoneAllowed else {
                    self.finish(withError: "Microphone access was denied, so nothing could be measured.")
                    return
                }
                do {
                    let recorder = try MicrophoneClickRecorder(inputDevice: AudioDevices.builtInMicrophone())
                    try recorder.start()
                    self.microphoneRecorder = recorder
                } catch {
                    self.finish(withError: "Couldn't start the microphone: \(error.localizedDescription)")
                    return
                }
                // Half a second of room noise before the first click.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.networkFeed = SimulatedNetworkFeed(
                        samples: ClickTrack.makeSamples(),
                        forcedGaps: [(afterContentSeconds: 3.0, gapSeconds: 1.2), (afterContentSeconds: 6.6, gapSeconds: 0.9)]
                    )
                }
            }
        }
    }

    private func updateClickMode(displayHostSeconds: Double) {
        guard let speechPlayer, let networkFeed else { return }
        networkFeed.deliverWhatHasArrived(to: speechPlayer)
        let heardContentSeconds = speechPlayer.update(predictingHeardAtHostSeconds: displayHostSeconds)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dueClick in wordScheduler.takeDueWords(from: ClickTrack.clickWords, heardContentSeconds: heardContentSeconds) {
            flashLayer.opacity = 1
            flashHostTimesByClickIndex[dueClick.wordIndex] = displayHostSeconds
            flashOffAtHostSeconds = displayHostSeconds + 0.1
        }
        if displayHostSeconds >= flashOffAtHostSeconds { flashLayer.opacity = 0 }
        CATransaction.commit()

        if speechPlayer.hasFinishedPlaying && finishedAtHostSeconds == nil {
            finishedAtHostSeconds = displayHostSeconds
        }
        if let finishedAtHostSeconds, displayHostSeconds - finishedAtHostSeconds > 1.0 {
            reportClickMeasurement()
        }
    }

    private func reportClickMeasurement() {
        guard let microphoneRecorder, let speechPlayer, let networkFeed else { return }
        microphoneRecorder.stop()
        let clickArrivalHostTimes = microphoneRecorder.clickArrivalHostTimes()

        var offsetsMilliseconds: [Double] = []
        var perClick: [[String: Any]] = []
        for (clickIndex, clickContentSeconds) in ClickTrack.clickContentTimes.enumerated() {
            var clickReport: [String: Any] = ["click": clickIndex, "contentSeconds": round(clickContentSeconds * 100) / 100]
            let justAfterAForcedGap = networkFeed.forcedGapContentTimes.contains { gapContentSeconds in
                clickContentSeconds >= gapContentSeconds - 0.5 && clickContentSeconds <= gapContentSeconds + 1.0
            }
            clickReport["nearForcedGap"] = justAfterAForcedGap
            if let flashHostSeconds = flashHostTimesByClickIndex[clickIndex],
               let nearestArrival = clickArrivalHostTimes.min(by: { abs($0 - flashHostSeconds) < abs($1 - flashHostSeconds) }),
               abs(nearestArrival - flashHostSeconds) < 0.5 {
                // Positive means the mark appeared after the sound.
                let offsetMilliseconds = (flashHostSeconds - nearestArrival) * 1000
                offsetsMilliseconds.append(offsetMilliseconds)
                clickReport["markMinusSoundMs"] = Int(offsetMilliseconds.rounded())
            } else {
                clickReport["markMinusSoundMs"] = NSNull()
            }
            perClick.append(clickReport)
        }

        let sortedAbsoluteOffsets = offsetsMilliseconds.map(abs).sorted()
        let sortedOffsets = offsetsMilliseconds.sorted()
        func percentile(_ sortedValues: [Double], _ fraction: Double) -> Double {
            guard !sortedValues.isEmpty else { return .nan }
            return sortedValues[min(sortedValues.count - 1, Int((Double(sortedValues.count - 1) * fraction).rounded()))]
        }
        let p95AbsoluteOffset = percentile(sortedAbsoluteOffsets, 0.95)
        // JSON can't hold NaN, and there's no error to report when nothing was matched.
        func wholeMillisecondsOrNull(_ milliseconds: Double?) -> Any {
            guard let milliseconds, milliseconds.isFinite else { return NSNull() }
            return Int(milliseconds.rounded())
        }

        result["outputDevice"] = speechPlayer.outputDeviceName
        result["inputDevice"] = microphoneRecorder.inputDeviceName
        result["reportedOutputLatencyMs"] = Int((speechPlayer.reportedOutputLatencySeconds * 1000).rounded())
        result["engineReportedOutputLatencyMs"] = Int((speechPlayer.engineReportedOutputLatencySeconds * 1000).rounded())
        result["reportedInputLatencyMs"] = Int((microphoneRecorder.reportedInputLatencySeconds * 1000).rounded())
        result["microphonePeakLevel"] = Double(microphoneRecorder.peakLevel)
        result["clicksPlayed"] = ClickTrack.clickCount
        result["clicksHeardByMicrophone"] = clickArrivalHostTimes.count
        result["clicksMatched"] = offsetsMilliseconds.count
        result["medianMarkMinusSoundMs"] = wholeMillisecondsOrNull(percentile(sortedOffsets, 0.5))
        result["p95AbsoluteErrorMs"] = wholeMillisecondsOrNull(p95AbsoluteOffset)
        result["worstAbsoluteErrorMs"] = wholeMillisecondsOrNull(sortedAbsoluteOffsets.last)
        result["outputVolume"] = speechPlayer.outputDeviceVolumeDescription
        result["flashesShown"] = flashHostTimesByClickIndex.count
        let recordingPath = (options.resultPath as NSString).deletingLastPathComponent + "/voice-sync-lab-microphone.wav"
        microphoneRecorder.writeRecording(toPath: recordingPath)
        result["microphoneRecording"] = recordingPath
        result["stalls"] = speechPlayer.stallGuard.stallCount
        result["timesPlayerRanDry"] = speechPlayer.timesPlayerRanDry
        result["largestPositionJumpAcrossAPauseMs"] = Int((speechPlayer.largestPositionJumpAcrossAPauseSeconds * 1000).rounded())
        result["perClick"] = perClick
        result["passes150msTarget"] = offsetsMilliseconds.count == ClickTrack.clickCount && p95AbsoluteOffset <= 150
        finish(withError: nil)
    }

    // MARK: - Speech mode

    private func startSpeechMode() {
        let contentView = window.contentView!
        contentView.layer?.backgroundColor = NSColor.white.cgColor
        textView = NSTextView(frame: contentView.bounds.insetBy(dx: 40, dy: 60))
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 28)
        textView.textColor = .black
        textView.string = lessonScript
        contentView.addSubview(textView)

        wordDotLayer.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        wordDotLayer.cornerRadius = 7
        wordDotLayer.backgroundColor = NSColor.systemRed.cgColor
        wordDotLayer.opacity = 0
        contentView.layer?.addSublayer(wordDotLayer)

        let wordPattern = try! NSRegularExpression(pattern: "\\S+")
        sentWordRanges = wordPattern.matches(in: lessonScript, range: NSRange(lessonScript.startIndex..., in: lessonScript)).map(\.range)
        wordScheduler = WordCueScheduler(leadSeconds: 0.08)

        guard let deviceToken = readWorkerDeviceToken() else {
            finish(withError: "No device token in the Keychain. Run scripts/mint-device-token.mjs.")
            return
        }
        let connection = VoiceConnection(workerBaseURL: workerBaseURL, deviceToken: deviceToken)
        voiceConnection = connection
        connection.open(
            onMessage: { [weak self] message in self?.receiveVoiceMessage(message) },
            onClose: { [weak self] reason in
                guard let self else { return }
                // Closing our own socket after the final message also lands here.
                self.voiceCloseReason = self.streamFinalReceived ? "closed by the lab after the final message" : reason
                self.connectionHasClosed = true
                // Messages held back for the forced stall still have to play, so the stream
                // only ends once they're released.
                if !self.streamFinalReceived && self.heldMessagesDuringForcedStall == nil { self.speechPlayer?.markStreamEnded() }
            }
        )

        // Send the script in small pieces, the way Claude's reply streams in. By default
        // ElevenLabs waits for about 120 characters before speaking, so a short first
        // block and a flush at each sentence end keep the first audio fast.
        connection.send(["text": " ", "generation_config": ["chunk_length_schedule": [50]]])
        let scriptPieces = splitIntoPieces(lessonScript, roughCharacterCount: 28)
        for (pieceIndex, piece) in scriptPieces.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(pieceIndex + 1)) {
                if self.firstTextSentHostSeconds == nil { self.firstTextSentHostSeconds = currentHostSeconds() }
                let pieceEndsASentence = piece.trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } ?? false
                connection.send(pieceEndsASentence ? ["text": piece, "flush": true] : ["text": piece])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(scriptPieces.count + 1)) {
            connection.send(["text": ""])
        }
    }

    /// Pieces never cross a sentence end, so the flush at each sentence end has something to flush.
    private func splitIntoPieces(_ text: String, roughCharacterCount: Int) -> [String] {
        var pieces: [String] = []
        var currentPiece = ""
        for word in text.split(separator: " ") {
            currentPiece += word + " "
            let wordEndsASentence = word.last.map { ".!?".contains($0) } ?? false
            if currentPiece.count >= roughCharacterCount || wordEndsASentence {
                pieces.append(currentPiece)
                currentPiece = ""
            }
        }
        if !currentPiece.isEmpty { pieces.append(currentPiece) }
        return pieces
    }

    private func receiveVoiceMessage(_ message: [String: Any]) {
        if var heldMessages = heldMessagesDuringForcedStall {
            heldMessages.append(message)
            heldMessagesDuringForcedStall = heldMessages
            return
        }
        applyVoiceMessage(message)

        // Holding the stream back once, mid-sentence, until the player has run out and
        // stayed paused for a second. Audio can arrive in bursts, so a fixed hold might not
        // empty the queue at all.
        if options.forceStallInSpeechMode && !forcedStallHasHappened && receivedAudioSeconds >= 1.5 && !streamFinalReceived {
            forcedStallHasHappened = true
            heldMessagesDuringForcedStall = []
            forcedStallStartedHostSeconds = currentHostSeconds()
            stallsBeforeForcedStall = speechPlayer?.stallGuard.stallCount ?? 0
        }
    }

    private func releaseForcedStallWhenItHasBitten(nowHostSeconds: Double) {
        guard heldMessagesDuringForcedStall != nil, let speechPlayer else { return }
        if speechPlayer.stallGuard.stallCount > stallsBeforeForcedStall && playerPausedDuringForcedStallAtHostSeconds == nil {
            playerPausedDuringForcedStallAtHostSeconds = nowHostSeconds
        }
        let pausedLongEnough = playerPausedDuringForcedStallAtHostSeconds.map { nowHostSeconds - $0 >= 1.0 } ?? false
        let heldTooLong = nowHostSeconds - forcedStallStartedHostSeconds > 20
        guard pausedLongEnough || heldTooLong else { return }
        let heldMessages = heldMessagesDuringForcedStall ?? []
        heldMessagesDuringForcedStall = nil
        heldMessages.forEach(applyVoiceMessage)
        if connectionHasClosed && !streamFinalReceived { speechPlayer.markStreamEnded() }
    }

    private func applyVoiceMessage(_ message: [String: Any]) {
        guard let speechPlayer else { return }
        var audioSecondsInThisMessage = 0.0
        if let audioBase64 = message["audio"] as? String, let audioData = Data(base64Encoded: audioBase64) {
            audioSecondsInThisMessage = Double(audioData.count / 2) / StreamingSpeechPlayer.sampleRate
            if firstAudioReceivedHostSeconds == nil && audioSecondsInThisMessage > 0 { firstAudioReceivedHostSeconds = currentHostSeconds() }
            speechPlayer.enqueue(pcm16Data: audioData)
        }
        // The alignment describes this message's own audio, so it's placed after the audio before it.
        if let alignment = message["alignment"] as? [String: Any],
           let characters = alignment["chars"] as? [String],
           let startTimes = alignment["charStartTimesMs"] as? [NSNumber],
           let durations = alignment["charDurationsMs"] as? [NSNumber] {
            speechTimeline.appendChunk(
                AlignedSpeechChunk(
                    characters: characters,
                    characterStartTimesMilliseconds: startTimes.map(\.doubleValue),
                    characterDurationsMilliseconds: durations.map(\.doubleValue)
                ),
                audioSecondsBeforeChunk: receivedAudioSeconds
            )
        }
        receivedAudioSeconds += audioSecondsInThisMessage
        if message["isFinal"] as? Bool == true {
            streamFinalReceived = true
            speechTimeline.finishStream()
            speechPlayer.markStreamEnded()
            voiceConnection?.close()
        }
    }

    private func updateSpeechMode(displayHostSeconds: Double) {
        guard let speechPlayer else { return }
        releaseForcedStallWhenItHasBitten(nowHostSeconds: currentHostSeconds())
        let heardContentSeconds = speechPlayer.update(predictingHeardAtHostSeconds: displayHostSeconds)
        if heardContentSeconds > 0 && firstAudioHeardHostSeconds == nil {
            firstAudioHeardHostSeconds = displayHostSeconds
        }

        for dueWord in wordScheduler.takeDueWords(from: speechTimeline.words, heardContentSeconds: heardContentSeconds) {
            cuedWordCount += 1
            moveDot(toSentWordAt: dueWord.wordIndex)
        }

        if speechPlayer.hasFinishedPlaying && finishedAtHostSeconds == nil {
            finishedAtHostSeconds = displayHostSeconds
        }
        if let finishedAtHostSeconds, displayHostSeconds - finishedAtHostSeconds > 0.8 {
            reportSpeechRun()
        }
    }

    private func moveDot(toSentWordAt wordIndex: Int) {
        guard wordIndex < sentWordRanges.count, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: sentWordRanges[wordIndex], actualCharacterRange: nil)
        let wordRectInTextView = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let wordRectInWindow = textView.convert(wordRectInTextView, to: window.contentView)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Just above the word, so the dot never covers it.
        wordDotLayer.position = CGPoint(x: wordRectInWindow.midX, y: wordRectInWindow.maxY + 10)
        wordDotLayer.opacity = 1
        CATransaction.commit()
    }

    private func reportSpeechRun() {
        guard let speechPlayer else { return }
        let wordStartTimes = speechTimeline.words.map(\.startSeconds)
        result["outputDevice"] = speechPlayer.outputDeviceName
        result["reportedOutputLatencyMs"] = Int((speechPlayer.reportedOutputLatencySeconds * 1000).rounded())
        result["forcedStall"] = options.forceStallInSpeechMode
        result["firstAudioHeardMsAfterFirstText"] = firstTextSentHostSeconds.flatMap { sentHostSeconds in
            firstAudioHeardHostSeconds.map { Int((($0 - sentHostSeconds) * 1000).rounded()) }
        } ?? NSNull()
        result["firstAudioReceivedMsAfterFirstText"] = firstTextSentHostSeconds.flatMap { sentHostSeconds in
            firstAudioReceivedHostSeconds.map { Int((($0 - sentHostSeconds) * 1000).rounded()) }
        } ?? NSNull()
        result["audioSeconds"] = (receivedAudioSeconds * 100).rounded() / 100
        result["wordsSent"] = sentWordRanges.count
        result["wordsTimed"] = speechTimeline.words.count
        result["wordsCued"] = cuedWordCount
        result["spokenTextMatchesSent"] = speechTimeline.checkSpokenTextMatches(sentText: lessonScript)
        result["wordTimesKeepIncreasing"] = zip(wordStartTimes, wordStartTimes.dropFirst()).allSatisfy { $0 <= $1 }
        result["chunksCountedFromStreamStart"] = speechTimeline.chunkTimeBases.filter { $0 == .countedFromStreamStart }.count
        result["chunksCountedFromChunkStart"] = speechTimeline.chunkTimeBases.filter { $0 == .countedFromChunkStart }.count
        result["timelineIssues"] = speechTimeline.issues.map { "\($0)" }
        result["lastWordEndsAtSeconds"] = speechTimeline.words.last.map { ($0.endSeconds * 100).rounded() / 100 } ?? NSNull()
        result["stalls"] = speechPlayer.stallGuard.stallCount
        result["timesPlayerRanDry"] = speechPlayer.timesPlayerRanDry
        result["largestPositionJumpAcrossAPauseMs"] = Int((speechPlayer.largestPositionJumpAcrossAPauseSeconds * 1000).rounded())
        result["voiceCloseReason"] = voiceCloseReason ?? "closed normally"
        finish(withError: nil)
    }

    // MARK: - Shared

    @objc private func screenWillRefresh(_ link: CADisplayLink) {
        // The frame being prepared appears at targetTimestamp, so marks are placed for then.
        if options.mode == "speech" {
            updateSpeechMode(displayHostSeconds: link.targetTimestamp)
        } else {
            updateClickMode(displayHostSeconds: link.targetTimestamp)
        }
        if currentHostSeconds() - labStartHostSeconds > 60 {
            finish(withError: "Timed out after 60 seconds.")
        }
    }

    private func finish(withError errorMessage: String?) {
        displayLink?.invalidate()
        displayLink = nil
        speechPlayer?.stop()
        if let errorMessage { result["error"] = errorMessage }
        if let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: options.resultPath, contents: resultData)
        }
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let labController = LabController()
application.delegate = labController
application.run()
