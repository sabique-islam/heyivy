import AppKit
import Darwin
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
//   --soak N          Run N whole lessons in a row and record memory, threads, open files,
//                     and CPU after each, then check the process for leaks (D7).
//   --worker URL      Use another Worker, such as scripts/fake-worker.mjs, which stalls or
//                     drops on purpose (D7).
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
    var soakLessonCount = 0
    var workerBaseURL = "https://secrets.worker.ivy.ivyx.me"

    init(arguments: [String]) {
        var argumentIndex = 1
        while argumentIndex < arguments.count {
            let nextValue = argumentIndex + 1 < arguments.count ? arguments[argumentIndex + 1] : ""
            switch arguments[argumentIndex] {
            case "--question": question = nextValue; argumentIndex += 1
            case "--result": resultPath = nextValue; argumentIndex += 1
            case "--force": forcedFailure = nextValue; argumentIndex += 1
            case "--interrupts": interruptCount = Int(nextValue) ?? 20; argumentIndex += 1
            case "--worker": workerBaseURL = nextValue; argumentIndex += 1
            case "--soak": soakLessonCount = Int(nextValue) ?? 100; argumentIndex += 1
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
        let secondsAllowed: Double = options.soakLessonCount > 0 ? Double(options.soakLessonCount) * 40 + 120 : (options.interruptCount > 0 ? 600 : 150)
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsAllowed) { [weak self] in self?.finish(withError: "Timed out.") }
    }

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
        if options.soakLessonCount > 0 {
            soakSamples.append(ProcessResourceSample.now(afterLesson: 0, outcome: "before any lesson"))
            runSoak(on: screen, deviceToken: deviceToken, lessonNumber: 1)
            return
        }
        var workerBaseURL = options.workerBaseURL
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
        let engine = LessonEngine(workerBaseURL: options.workerBaseURL, deviceToken: deviceToken, markOverlay: markOverlay, timingLog: LessonTimingLog(), watchesScreenForChanges: false)
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

    private var soakSamples: [ProcessResourceSample] = []

    /// Whole lessons, one after another, as someone using Ivy all afternoon would. Each
    /// engine is released before the next starts, so anything still growing is a leak.
    private func runSoak(on screen: NSScreen, deviceToken: String, lessonNumber: Int) {
        guard lessonNumber <= options.soakLessonCount else { return finishSoak() }
        guard let lessonScreen = renderScreenshot(of: screen) else { return finish(withError: "Couldn't draw the screenshot.") }
        let engine = LessonEngine(workerBaseURL: options.workerBaseURL, deviceToken: deviceToken, markOverlay: markOverlay, timingLog: LessonTimingLog(), watchesScreenForChanges: false)
        var hasEnded = false
        let endLesson: (String) -> Void = { [weak self, weak engine] outcome in
            guard let self, !hasEnded else { return }
            hasEnded = true
            // Marks stay 3 seconds after speech, and the next lesson clears them anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                engine?.cancel()
                self.markOverlay.clearAll()
                self.soakSamples.append(ProcessResourceSample.now(afterLesson: lessonNumber, outcome: outcome))
                if lessonNumber == 10 { Self.recordHeapAndMemoryRegions(toPathsStartingWith: self.options.resultPath + ".lesson-10") }
                self.runSoak(on: screen, deviceToken: deviceToken, lessonNumber: lessonNumber + 1)
            }
        }
        engine.onFinished = { endLesson("spoken") }
        // Weak, because the engine holds these callbacks, and holding it back would be a leak
        // of the lab's own making.
        engine.onFailed = { [weak engine] failure in
            // After a voice failure the answer still arrives as text, which ends the lesson.
            if failure == .voiceFailed, let engine, engine.hasScriptFinished == false {
                engine.onScriptFinished = { _ in endLesson("voice failed, shown as text") }
            } else {
                endLesson("failed: \(failure)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { endLesson("stuck") }
        // The one strong reference, replaced by the next lesson's engine.
        lessonEngine = engine
        engine.run(question: options.question, screen: lessonScreen, history: [])
    }

    private func finishSoak() {
        let outcomeCounts = Dictionary(grouping: soakSamples.dropFirst(), by: \.outcome).mapValues(\.count)
        result["soakSamples"] = soakSamples.map(\.report)
        result["soakOutcomes"] = outcomeCounts
        // Growth is judged from lesson 10 on, after caches and first-use setup have filled.
        let settledSamples = soakSamples.filter { $0.lessonNumber >= 10 }
        if let firstSettled = settledSamples.first, let lastSettled = settledSamples.last, lastSettled.lessonNumber > firstSettled.lessonNumber {
            let lessonsBetween = Double(lastSettled.lessonNumber - firstSettled.lessonNumber)
            result["soakGrowthFromLesson10"] = [
                "lessons": lastSettled.lessonNumber - firstSettled.lessonNumber,
                "footprintMB": [firstSettled.footprintMegabytes, lastSettled.footprintMegabytes],
                "footprintKBPerLesson": ((lastSettled.footprintMegabytes - firstSettled.footprintMegabytes) * 1024 / lessonsBetween).rounded(),
                "threads": [firstSettled.threadCount, lastSettled.threadCount],
                "openFiles": [firstSettled.openFileCount, lastSettled.openFileCount],
            ] as [String: Any]
        }
        if let lastSample = soakSamples.last, soakSamples.count > 1 {
            result["soakCPUSecondsPerLesson"] = (lastSample.cpuSeconds - soakSamples[0].cpuSeconds) / Double(soakSamples.count - 1)
        }
        lessonEngine = nil
        Self.recordHeapAndMemoryRegions(toPathsStartingWith: options.resultPath + ".lesson-\(options.soakLessonCount)")
        result["leaksCheck"] = Self.checkThisProcessForLeaks(fullOutputPath: options.resultPath + ".leaks.txt")
        finish(withError: nil)
    }

    /// What's allocated, by class, and how much memory each kind of region holds, so two
    /// points in a soak can be compared to see what grew.
    private static func recordHeapAndMemoryRegions(toPathsStartingWith pathPrefix: String) {
        for (toolPath, arguments, suffix) in [("/usr/bin/heap", ["\(getpid())"], ".heap.txt"), ("/usr/bin/vmmap", ["--summary", "\(getpid())"], ".vmmap.txt")] {
            let toolProcess = Process()
            toolProcess.executableURL = URL(fileURLWithPath: toolPath)
            toolProcess.arguments = arguments
            let outputPipe = Pipe()
            toolProcess.standardOutput = outputPipe
            toolProcess.standardError = outputPipe
            guard (try? toolProcess.run()) != nil else { continue }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            toolProcess.waitUntilExit()
            FileManager.default.createFile(atPath: pathPrefix + suffix, contents: outputData)
        }
    }

    /// Runs Apple's leaks tool on this process, keeps its full report beside the result, and
    /// returns its summary line, such as "Process 123: 0 leaks for 0 total leaked bytes."
    private static func checkThisProcessForLeaks(fullOutputPath: String) -> String {
        let leaksProcess = Process()
        leaksProcess.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        leaksProcess.arguments = ["\(getpid())"]
        let outputPipe = Pipe()
        leaksProcess.standardOutput = outputPipe
        leaksProcess.standardError = outputPipe
        do { try leaksProcess.run() } catch { return "leaks didn't run: \(error.localizedDescription)" }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        leaksProcess.waitUntilExit()
        FileManager.default.createFile(atPath: fullOutputPath, contents: outputData)
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        return outputText.split(separator: "\n").first(where: { $0.contains("leaks for") }).map(String.init)
            ?? "no summary line, exit status \(leaksProcess.terminationStatus)"
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

/// How much of the Mac this process holds after a lesson.
struct ProcessResourceSample {
    var lessonNumber: Int
    var outcome: String
    var footprintMegabytes: Double
    var threadCount: Int
    var openFileCount: Int
    var cpuSeconds: Double

    static func now(afterLesson lessonNumber: Int, outcome: String) -> ProcessResourceSample {
        // The footprint is what Activity Monitor shows as Memory.
        var vmInfo = task_vm_info_data_t()
        var vmInfoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let vmInfoResult = withUnsafeMutablePointer(to: &vmInfo) { vmInfoPointer in
            vmInfoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmInfoCount)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmInfoCount) }
        }
        let footprintBytes = vmInfoResult == KERN_SUCCESS ? Double(vmInfo.phys_footprint) : -1

        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        if task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threadList {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        let openFileCount = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1

        var resourceUsage = rusage()
        getrusage(RUSAGE_SELF, &resourceUsage)
        let cpuSeconds = Double(resourceUsage.ru_utime.tv_sec + resourceUsage.ru_stime.tv_sec) + Double(resourceUsage.ru_utime.tv_usec + resourceUsage.ru_stime.tv_usec) / 1_000_000

        return ProcessResourceSample(
            lessonNumber: lessonNumber, outcome: outcome,
            footprintMegabytes: (footprintBytes / 1_048_576 * 10).rounded() / 10,
            threadCount: Int(threadCount), openFileCount: openFileCount,
            cpuSeconds: (cpuSeconds * 100).rounded() / 100
        )
    }

    var report: [String: Any] {
        ["lesson": lessonNumber, "outcome": outcome, "footprintMB": footprintMegabytes, "threads": threadCount, "openFiles": openFileCount, "cpuSeconds": cpuSeconds]
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let labController = LabController()
    application.delegate = labController
    application.run()
}
