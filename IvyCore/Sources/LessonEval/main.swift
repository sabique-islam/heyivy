import AppKit
import CryptoKit
import IvyCore
import IvyLesson
import WebKit

// LessonEval: grades Ivy's marks on the evaluation screens in eval/cases (drawing plan, D6).
//
// Each case is rendered like a real screen, then put through what the app does with a
// question: the same prompt, the live Worker and model, on-device text recognition, and
// the same mark resolver. There's no voice, because sync was measured in D1 and D4, and
// what this checks is whether the marks land on the right things.
//
//   --split dev|test|all  Which cases. Default dev. "test" is the held-back third: run it
//                         to report a result, never to tune the prompt against.
//   --only ID,ID          Just these cases.
//   --trials N            Run each case N times, since answers vary. Default 1.
//   --label NAME          Names the run, like "baseline" or "prompt-v2".
//   --model-note TEXT     The Worker's model and settings, recorded with the results.
//   --output DIR          Where results go. Default eval/results/<time>-<label>.
//
// Run it with scripts/lesson-eval.sh. Each case costs under a cent.

struct EvalOptions {
    var casesPath = "eval/cases/cases.json"
    var split = "dev"
    var onlyCaseIDs: Set<String> = []
    var trials = 1
    var label = "run"
    var modelNote = "unknown"
    var outputDirectory: String?

    init(arguments: [String]) {
        var argumentIndex = 1
        while argumentIndex < arguments.count {
            let nextValue = argumentIndex + 1 < arguments.count ? arguments[argumentIndex + 1] : ""
            switch arguments[argumentIndex] {
            case "--cases": casesPath = nextValue; argumentIndex += 1
            case "--split": split = nextValue; argumentIndex += 1
            case "--only": onlyCaseIDs = Set(nextValue.split(separator: ",").map(String.init)); argumentIndex += 1
            case "--trials": trials = max(1, Int(nextValue) ?? 1); argumentIndex += 1
            case "--label": label = nextValue; argumentIndex += 1
            case "--model-note": modelNote = nextValue; argumentIndex += 1
            case "--output": outputDirectory = nextValue; argumentIndex += 1
            default: break
            }
            argumentIndex += 1
        }
    }
}

struct EvalCase: Decodable {
    var id: String
    var category: String
    var question: String
    var split: String
    var screen: String
    var expectsNoMarks: Bool?
    var hostileCanary: String?
}

struct CaseCatalog: Decodable {
    var viewportPoints: [Int]
    var cases: [EvalCase]
}

/// One rendered screen: the full-resolution image, and every marked box in points.
struct RenderedScreen {
    var fullResolutionImage: CGImage
    var boxesInPoints: [GroundTruthBox]
    /// Every piece of text on the page, so a mark off the target can be checked against
    /// the words it names.
    var pageTextsInPoints: [PageText]
}

/// Draws each case's page in a window that's never shown, and reads its marked boxes.
@MainActor
final class ScreenRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?

    init(viewportPoints: CGSize) {
        webView = WKWebView(frame: CGRect(origin: .zero, size: viewportPoints))
        // Off every screen, so it never covers anything, but still drawn at Retina scale.
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: viewportPoints), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
        window.orderFrontRegardless()
    }

    func render(pageURL: URL, viewportPoints: CGSize, pixelsPerPoint: CGFloat) async throws -> RenderedScreen {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }
        // Fonts and layout settle a moment after loading finishes.
        try await Task.sleep(nanoseconds: 150_000_000)

        let boxScript = """
        [...document.querySelectorAll('[data-target],[data-ok],[data-hostile]')].map(element => {
          const box = element.getBoundingClientRect();
          const role = element.hasAttribute('data-hostile') ? 'hostile' : element.hasAttribute('data-target') ? 'target' : 'acceptable';
          return [role, box.x, box.y, box.width, box.height];
        })
        """
        let boxValues = try await webView.evaluateJavaScript(boxScript) as? [[Any]] ?? []
        let boxes = boxValues.compactMap { values -> GroundTruthBox? in
            guard values.count == 5, let roleName = values[0] as? String, let role = GroundTruthBox.Role(rawValue: roleName),
                  let x = values[1] as? Double, let y = values[2] as? Double, let width = values[3] as? Double, let height = values[4] as? Double,
                  width > 0, height > 0 else { return nil }
            return GroundTruthBox(role: role, rect: CGRect(x: x, y: y, width: width, height: height))
        }

        // One box per line of each text node, since a long sentence wraps.
        let textScript = """
        (() => {
          const found = [];
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (!node.textContent.trim()) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            for (const box of range.getClientRects()) {
              if (box.width > 0 && box.height > 0) found.push([node.textContent, box.x, box.y, box.width, box.height]);
            }
          }
          // A value in a field, like a width of 220, shows on screen but isn't a text node.
          for (const field of document.querySelectorAll('input')) {
            const box = field.getBoundingClientRect();
            if (field.value && box.width > 0) found.push([field.value, box.x, box.y, box.width, box.height]);
          }
          return found;
        })()
        """
        let textValues = try await webView.evaluateJavaScript(textScript) as? [[Any]] ?? []
        let pageTexts = textValues.compactMap { values -> PageText? in
            guard values.count == 5, let text = values[0] as? String,
                  let x = values[1] as? Double, let y = values[2] as? Double, let width = values[3] as? Double, let height = values[4] as? Double else { return nil }
            return PageText(text: text, rect: CGRect(x: x, y: y, width: width, height: height))
        }

        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = CGRect(origin: .zero, size: viewportPoints)
        snapshotConfiguration.afterScreenUpdates = true
        snapshotConfiguration.snapshotWidth = NSNumber(value: Double(viewportPoints.width))
        let snapshot = try await webView.takeSnapshot(configuration: snapshotConfiguration)
        // Drawn into a bitmap of exactly the size a Retina screen capture would be.
        let pixelWidth = Int(viewportPoints.width * pixelsPerPoint)
        let pixelHeight = Int(viewportPoints.height * pixelsPerPoint)
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EvalError(message: "Couldn't make a bitmap for the screen.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        snapshot.draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        NSGraphicsContext.restoreGraphicsState()
        guard let fullResolutionImage = context.makeImage() else { throw EvalError(message: "Couldn't draw the screen.") }
        return RenderedScreen(fullResolutionImage: fullResolutionImage, boxesInPoints: boxes, pageTextsInPoints: pageTexts)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

struct EvalError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// Everything recorded about one run of one case.
struct TrialRecord: Encodable {
    var caseID: String
    var category: String
    var split: String
    var trial: Int
    var question: String
    var passed: Bool
    var failureReasons: [String]
    var spokenText: String
    var marks: [MarkRecord]
    var droppedByParser: [String]
    var drawnMarkCount: Int
    var marksOnTarget: Int
    var marksOnAcceptable: Int
    var marksOnHostile: Int
    var marksOnWhatTheyNamed: Int
    var marksUnverified: Int
    var marksElsewhere: Int
    var firstTextMilliseconds: Int?
    var totalMilliseconds: Int
    var inputTokens: Int
    var outputTokens: Int
    var estimatedCostUSD: Double
    var recognizedWordCount: Int
    /// What text recognition read, when a mark was dropped or landed somewhere wrong, to
    /// see why. The screens are made up, so this holds nothing private.
    var recognizedWordsForReview: [String]?
    var error: String?
}

struct MarkRecord: Encodable {
    var kind: String
    var target: String
    var roughPosition: String
    var outcome: String
    var landing: String?
}

/// What the Worker charges for Sonnet 5.5, from worker/src/policy.ts. Cached tokens cost
/// less, so this is an upper estimate.
let inputUSDPerToken = 2.0 / 1_000_000
let outputUSDPerToken = 10.0 / 1_000_000

final class TokenUsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (input: 0, output: 0)
    func store(input: Int, output: Int) { lock.withLock { counts = (input, output) } }
    var value: (input: Int, output: Int) { lock.withLock { counts } }
}

@MainActor
final class EvalController: NSObject, NSApplicationDelegate {
    private let options = EvalOptions(arguments: CommandLine.arguments)
    private var trialRecords: [TrialRecord] = []
    private var outputDirectory: URL!
    private var reviewDirectory: URL!

    // The Worker allows 20 chat requests a minute per device. This stays under it.
    private static let secondsBetweenRequests = 3.4
    private static let largestNumberInFlight = 3
    private static let sentImageWidth = 1280

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    private func run() async {
        let catalogURL = URL(fileURLWithPath: options.casesPath)
        let catalog: CaseCatalog
        do {
            catalog = try JSONDecoder().decode(CaseCatalog.self, from: Data(contentsOf: catalogURL))
        } catch {
            return finish(withError: "Couldn't read \(options.casesPath): \(error)")
        }
        guard let deviceToken = readWorkerDeviceToken() else {
            return finish(withError: "No device token in the Keychain. Run scripts/mint-device-token.mjs.")
        }

        let selectedCases = catalog.cases.filter { evalCase in
            if !options.onlyCaseIDs.isEmpty { return options.onlyCaseIDs.contains(evalCase.id) }
            return options.split == "all" || evalCase.split == options.split
        }
        guard !selectedCases.isEmpty else { return finish(withError: "No cases match.") }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "").prefix(15)
        outputDirectory = URL(fileURLWithPath: options.outputDirectory ?? "eval/results/\(timestamp)-\(options.label)")
        reviewDirectory = outputDirectory.appendingPathComponent("review")
        try? FileManager.default.createDirectory(at: reviewDirectory, withIntermediateDirectories: true)

        let viewportPoints = CGSize(width: catalog.viewportPoints[0], height: catalog.viewportPoints[1])
        let pixelsPerPoint: CGFloat = 2
        let sentImageSize = CGSize(width: Self.sentImageWidth, height: Int((Double(Self.sentImageWidth) * viewportPoints.height / viewportPoints.width).rounded()))
        let renderer = ScreenRenderer(viewportPoints: viewportPoints)
        print("Warming up text recognition…")
        _ = await Task.detached { ScreenTextRecognizer.warmUp() }.value

        let trialsToRun = selectedCases.flatMap { evalCase in (1...options.trials).map { (evalCase, $0) } }
        print("Running \(trialsToRun.count) trial\(trialsToRun.count == 1 ? "" : "s") of \(selectedCases.count) case\(selectedCases.count == 1 ? "" : "s") (split \(options.split)).")
        var runningTrials: [Task<Void, Never>] = []
        var nextRequestUptime = ProcessInfo.processInfo.systemUptime
        for (evalCase, trial) in trialsToRun {
            // Rendering shares one web view, so it happens here, one case at a time.
            let rendered: RenderedScreen
            do {
                rendered = try await renderer.render(pageURL: catalogURL.deletingLastPathComponent().appendingPathComponent(evalCase.screen), viewportPoints: viewportPoints, pixelsPerPoint: pixelsPerPoint)
            } catch {
                trialRecords.append(Self.errorRecord(evalCase: evalCase, trial: trial, error: "render failed: \(error)"))
                continue
            }
            while runningTrials.count >= Self.largestNumberInFlight {
                await runningTrials.removeFirst().value
            }
            let waitSeconds = nextRequestUptime - ProcessInfo.processInfo.systemUptime
            if waitSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000)) }
            nextRequestUptime = ProcessInfo.processInfo.systemUptime + Self.secondsBetweenRequests
            runningTrials.append(Task {
                let record = await self.runTrial(evalCase: evalCase, trial: trial, rendered: rendered, viewportPoints: viewportPoints, sentImageSize: sentImageSize, deviceToken: deviceToken)
                self.trialRecords.append(record)
                print("  \(record.passed ? "pass" : "FAIL") \(record.caseID)\(self.options.trials > 1 ? " #\(trial)" : "") \(record.failureReasons.joined(separator: "; "))")
            })
        }
        for runningTrial in runningTrials { await runningTrial.value }
        writeResults(sentImageSize: sentImageSize)
        finish(withError: nil)
    }

    private func runTrial(evalCase: EvalCase, trial: Int, rendered: RenderedScreen, viewportPoints: CGSize, sentImageSize: CGSize, deviceToken: String) async -> TrialRecord {
        let startUptime = ProcessInfo.processInfo.systemUptime
        let pixelsPerSentPixel = sentImageSize.width / viewportPoints.width
        func inSentPixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * pixelsPerSentPixel, y: rect.minY * pixelsPerSentPixel, width: rect.width * pixelsPerSentPixel, height: rect.height * pixelsPerSentPixel)
        }
        let groundTruth = rendered.boxesInPoints.map { GroundTruthBox(role: $0.role, rect: inSentPixels($0.rect)) }
        let pageTexts = rendered.pageTextsInPoints.map { PageText(text: $0.text, rect: inSentPixels($0.rect)) }
        guard let sentImage = Self.shrink(rendered.fullResolutionImage, to: sentImageSize),
              let jpegData = NSBitmapImageRep(cgImage: sentImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return Self.errorRecord(evalCase: evalCase, trial: trial, error: "couldn't make the screenshot")
        }

        let fullResolutionImage = rendered.fullResolutionImage
        let recognitionTask = Task.detached { (try? ScreenTextRecognizer.recognizeWords(in: fullResolutionImage, reportedInPixelSize: sentImageSize)) ?? [] }

        let tokenUsage = TokenUsageBox()
        var scriptParser = LessonScriptParser()
        var spokenText = ""
        var markRequests: [MarkRequest] = []
        var firstTextMilliseconds: Int?
        var streamError: String?
        do {
            for try await scriptText in ClaudeScriptStream.streamScript(
                workerBaseURL: "https://secrets.worker.ivy.ivyx.me",
                deviceToken: deviceToken,
                systemPrompt: LessonPrompt.systemPrompt(imageWidth: Int(sentImageSize.width), imageHeight: Int(sentImageSize.height)),
                screenshotJPEGData: jpegData,
                screenshotLabel: "The user's screen, \(Int(sentImageSize.width))x\(Int(sentImageSize.height)) pixels.",
                question: evalCase.question,
                history: [],
                onTokenUsage: { input, output in tokenUsage.store(input: input, output: output) }
            ) {
                if firstTextMilliseconds == nil { firstTextMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - startUptime) * 1000).rounded()) }
                for output in scriptParser.consume(scriptText) { Self.collect(output, spokenText: &spokenText, markRequests: &markRequests) }
            }
            for output in scriptParser.finish() { Self.collect(output, spokenText: &spokenText, markRequests: &markRequests) }
        } catch {
            streamError = "answer failed: \(error)"
        }
        let recognizedWords = await recognitionTask.value

        var markRecords: [MarkRecord] = []
        var landings: [MarkLanding] = []
        var drawnBoxes: [(box: CGRect, landing: MarkLanding)] = []
        for markRequest in markRequests {
            var resolution = TargetResolver.resolve(mark: markRequest, recognizedWords: recognizedWords, imagePixelSize: sentImageSize)
            // As LessonEngine does: text not found on the whole screen is looked for again in
            // the area around Claude's position.
            if resolution == .dropped(.textNotFound) {
                let roughPoint = CGPoint(x: markRequest.roughPositionInImagePixels.x, y: markRequest.roughPositionInImagePixels.y)
                let areaWords = await Task.detached { (try? ScreenTextRecognizer.recognizeWords(in: fullResolutionImage, around: roughPoint, reportedInPixelSize: sentImageSize, firstLineIndex: 100_000)) ?? [] }.value
                resolution = TargetResolver.resolve(mark: markRequest, recognizedWords: recognizedWords + areaWords, imagePixelSize: sentImageSize)
            }
            let roughPosition = "\(Int(markRequest.roughPositionInImagePixels.x)),\(Int(markRequest.roughPositionInImagePixels.y))"
            var markRecord = MarkRecord(kind: markRequest.kind.rawValue, target: "\(markRequest.target)", roughPosition: roughPosition, outcome: "", landing: nil)
            let drawnBox: CGRect?
            switch resolution {
            case .drawOnText(let box, let matchQuality):
                markRecord.outcome = "drawn on text (\(matchQuality))"
                drawnBox = box
            case .drawAroundPosition(let box):
                markRecord.outcome = "drawn at position"
                drawnBox = box
            case .dropped(let reason):
                markRecord.outcome = "dropped: \(reason)"
                drawnBox = nil
            }
            if let drawnBox {
                var namedWords: [String] = []
                if case .visibleText(let words) = markRequest.target { namedWords = words }
                let landing = MarkGrading.landing(ofMarkBox: drawnBox, kind: markRequest.kind, groundTruth: groundTruth, namedWords: namedWords, pageTexts: pageTexts)
                markRecord.landing = landing.rawValue
                landings.append(landing)
                drawnBoxes.append((drawnBox, landing))
            }
            markRecords.append(markRecord)
        }

        var grade = MarkGrading.grade(landings: landings, expectsNoMarks: evalCase.expectsNoMarks ?? false, hostileCanary: evalCase.hostileCanary, spokenText: spokenText)
        if let streamError {
            grade.passed = false
            grade.failureReasons.insert(streamError, at: 0)
        }
        let roughPositions = markRequests.map { CGPoint(x: $0.roughPositionInImagePixels.x, y: $0.roughPositionInImagePixels.y) }
        writeReviewImage(sentImage: sentImage, groundTruth: groundTruth, drawnBoxes: drawnBoxes, roughPositions: roughPositions, name: "\(evalCase.id)\(options.trials > 1 ? "-\(trial)" : "")")

        let usage = tokenUsage.value
        return TrialRecord(
            caseID: evalCase.id, category: evalCase.category, split: evalCase.split, trial: trial, question: evalCase.question,
            passed: grade.passed, failureReasons: grade.failureReasons, spokenText: spokenText, marks: markRecords,
            droppedByParser: scriptParser.droppedMarks.map { "\($0)" },
            drawnMarkCount: grade.drawnMarkCount, marksOnTarget: grade.marksOnTarget, marksOnAcceptable: grade.marksOnAcceptable,
            marksOnHostile: grade.marksOnHostile, marksOnWhatTheyNamed: grade.marksOnWhatTheyNamed, marksUnverified: grade.marksUnverified, marksElsewhere: grade.marksElsewhere,
            firstTextMilliseconds: firstTextMilliseconds,
            totalMilliseconds: Int(((ProcessInfo.processInfo.systemUptime - startUptime) * 1000).rounded()),
            inputTokens: usage.input, outputTokens: usage.output,
            estimatedCostUSD: Double(usage.input) * inputUSDPerToken + Double(usage.output) * outputUSDPerToken,
            recognizedWordCount: recognizedWords.count,
            recognizedWordsForReview: markRecords.contains { $0.outcome.hasPrefix("dropped") || $0.landing == "elsewhere" }
                ? recognizedWords.map { "\($0.text) @\(Int($0.boxInImagePixels.minX)),\(Int($0.boxInImagePixels.minY)) line \($0.lineIndex)" }
                : nil,
            error: streamError
        )
    }

    private static func collect(_ output: ScriptParserOutput, spokenText: inout String, markRequests: inout [MarkRequest]) {
        switch output {
        case .speech(let speechText): spokenText += speechText
        case .mark(let markRequest): markRequests.append(markRequest)
        }
    }

    private static func errorRecord(evalCase: EvalCase, trial: Int, error: String) -> TrialRecord {
        TrialRecord(caseID: evalCase.id, category: evalCase.category, split: evalCase.split, trial: trial, question: evalCase.question,
                    passed: false, failureReasons: [error], spokenText: "", marks: [], droppedByParser: [], drawnMarkCount: 0,
                    marksOnTarget: 0, marksOnAcceptable: 0, marksOnHostile: 0, marksOnWhatTheyNamed: 0, marksUnverified: 0, marksElsewhere: 0, firstTextMilliseconds: nil,
                    totalMilliseconds: 0, inputTokens: 0, outputTokens: 0, estimatedCostUSD: 0, recognizedWordCount: 0, recognizedWordsForReview: nil, error: error)
    }

    private static func shrink(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    /// The screen Claude saw, with the right boxes in green (target), blue (also fine) and
    /// red (hostile), Claude's rough positions as small crosses, and each drawn mark in
    /// yellow when it landed right, gray when it's on what it named but not the target,
    /// and magenta when it's wrong.
    private func writeReviewImage(sentImage: CGImage, groundTruth: [GroundTruthBox], drawnBoxes: [(box: CGRect, landing: MarkLanding)], roughPositions: [CGPoint], name: String) {
        let width = sentImage.width
        let height = sentImage.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(sentImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Boxes are measured from the top, and Core Graphics draws from the bottom.
        func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height) }
        context.setLineWidth(2)
        for box in groundTruth {
            switch box.role {
            case .target: context.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1))
            case .acceptable: context.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 1))
            case .hostile: context.setStrokeColor(CGColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: 1))
            }
            context.stroke(flipped(box.rect))
        }
        context.setLineWidth(3)
        for drawn in drawnBoxes {
            switch drawn.landing {
            case .onTarget, .onAcceptable: context.setStrokeColor(CGColor(srgbRed: 1, green: 0.79, blue: 0.24, alpha: 1))
            case .onWhatItNamed, .unverified: context.setStrokeColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1))
            case .onHostile, .elsewhere: context.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0.8, alpha: 1))
            }
            context.stroke(flipped(drawn.box.insetBy(dx: -3, dy: -3)))
        }
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 1))
        context.setLineWidth(2)
        for roughPosition in roughPositions {
            let point = CGPoint(x: roughPosition.x, y: Double(height) - roughPosition.y)
            context.strokeLineSegments(between: [CGPoint(x: point.x - 7, y: point.y), CGPoint(x: point.x + 7, y: point.y), CGPoint(x: point.x, y: point.y - 7), CGPoint(x: point.x, y: point.y + 7)])
        }
        guard let reviewImage = context.makeImage(),
              let pngData = NSBitmapImageRep(cgImage: reviewImage).representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: reviewDirectory.appendingPathComponent("\(name).png"))
    }

    private func writeResults(sentImageSize: CGSize) {
        let sortedRecords = trialRecords.sorted { ($0.caseID, $0.trial) < ($1.caseID, $1.trial) }
        let promptText = LessonPrompt.systemPrompt(imageWidth: Int(sentImageSize.width), imageHeight: Int(sentImageSize.height))
        let promptHash = SHA256.hash(data: Data(promptText.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        let runInfo: [String: Any] = [
            "label": options.label, "split": options.split, "trials": options.trials, "modelNote": options.modelNote,
            "promptSHA256Prefix": String(promptHash), "date": ISO8601DateFormatter().string(from: Date()),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let recordsData = try? encoder.encode(sortedRecords),
           let recordsJSON = try? JSONSerialization.jsonObject(with: recordsData),
           let resultsData = try? JSONSerialization.data(withJSONObject: ["run": runInfo, "trials": recordsJSON], options: [.prettyPrinted, .sortedKeys]) {
            try? resultsData.write(to: outputDirectory.appendingPathComponent("results.json"))
        }

        // The same trials in the shape Sui's eval_report.py reads, for paired comparisons.
        let suiTrials = sortedRecords.map { record -> [String: Any] in
            ["caseId": record.caseID, "variant": options.label, "split": record.split, "passed": record.passed,
             "latencyMs": record.firstTextMilliseconds ?? record.totalMilliseconds, "costUsd": record.estimatedCostUSD, "trialId": "\(record.trial)"]
        }
        if let suiData = try? JSONSerialization.data(withJSONObject: ["trials": suiTrials], options: [.prettyPrinted, .sortedKeys]) {
            try? suiData.write(to: outputDirectory.appendingPathComponent("trials-for-eval-report.json"))
        }

        let summary = Self.summary(of: sortedRecords, runInfo: runInfo)
        try? summary.write(to: outputDirectory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print("\n" + summary)
        print("Results: \(outputDirectory.path)")
    }

    static func summary(of records: [TrialRecord], runInfo: [String: Any]) -> String {
        func percent(_ part: Int, _ whole: Int) -> String { whole == 0 ? "–" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%" }
        func median(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.sorted()[values.count / 2] }
        func percentile95(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.sorted()[min(values.count - 1, Int((Double(values.count) * 0.95).rounded(.up)) - 1)] }

        var lines: [String] = []
        lines.append("# Lesson eval: \(runInfo["label"] ?? "")")
        lines.append("")
        lines.append("Split \(runInfo["split"] ?? ""), \(runInfo["trials"] ?? 1) trial(s) per case, prompt \(runInfo["promptSHA256Prefix"] ?? ""), model \(runInfo["modelNote"] ?? ""), \(runInfo["date"] ?? "").")
        lines.append("")
        lines.append("| Screen type | Trials | Passed | Any mark drawn | Hit the target | Trials with a wrong mark | Wrong marks / drawn | Secondary marks | For review | Dropped marks |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|")
        let categories = Array(Set(records.map(\.category))).sorted()
        for category in categories + ["All"] {
            let rows = category == "All" ? records : records.filter { $0.category == category }
            let drawn = rows.map(\.drawnMarkCount).reduce(0, +)
            let wrong = rows.map { $0.marksElsewhere + $0.marksOnHostile }.reduce(0, +)
            let dropped = rows.map { $0.marks.filter { $0.outcome.hasPrefix("dropped") }.count + $0.droppedByParser.count }.reduce(0, +)
            let requested = rows.map { $0.marks.count + $0.droppedByParser.count }.reduce(0, +)
            let screenRows = rows.filter { !$0.question.isEmpty && $0.category != "not about the screen" }
            let secondary = rows.map(\.marksOnWhatTheyNamed).reduce(0, +)
            let name = category == "All" ? "**All**" : category
            let hitTarget = screenRows.filter { $0.marksOnTarget + $0.marksOnAcceptable > 0 }.count
            lines.append("| \(name) | \(rows.count) | \(percent(rows.filter(\.passed).count, rows.count)) | \(percent(rows.filter { $0.drawnMarkCount > 0 }.count, rows.count)) | \(percent(hitTarget, screenRows.count)) | \(percent(rows.filter { $0.marksElsewhere + $0.marksOnHostile > 0 }.count, rows.count)) | \(percent(wrong, drawn)) | \(secondary) | \(rows.map(\.marksUnverified).reduce(0, +)) | \(dropped) of \(requested) |")
        }
        let firstTextTimes = records.compactMap(\.firstTextMilliseconds)
        let cost = records.map(\.estimatedCostUSD).reduce(0, +)
        lines.append("")
        lines.append("First text: median \(median(firstTextTimes).map { "\($0) ms" } ?? "–"), 95th percentile \(percentile95(firstTextTimes).map { "\($0) ms" } ?? "–"). Estimated cost $\(String(format: "%.2f", cost)), about $\(String(format: "%.4f", records.isEmpty ? 0 : cost / Double(records.count))) a trial.")
        let errors = records.filter { $0.error != nil }.count
        if errors > 0 { lines.append("\(errors) trial(s) failed to get an answer, and count as failures.") }
        var droppedReasons: [String: Int] = [:]
        for record in records {
            for mark in record.marks where mark.outcome.hasPrefix("dropped") { droppedReasons[mark.outcome, default: 0] += 1 }
            for parserDrop in record.droppedByParser { droppedReasons["parser: \(parserDrop)", default: 0] += 1 }
        }
        if !droppedReasons.isEmpty {
            lines.append("")
            lines.append("Why marks were dropped: " + droppedReasons.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ".")
        }
        let needingReview = records.filter { $0.marksUnverified > 0 }
        if !needingReview.isEmpty {
            lines.append("")
            lines.append("Marks without words that missed the target, for a person to judge from the review images: " + needingReview.map { "`\($0.caseID)` (\($0.marksUnverified))" }.joined(separator: ", ") + ".")
        }
        let failures = records.filter { !$0.passed }
        if !failures.isEmpty {
            lines.append("")
            lines.append("## Failures")
            lines.append("")
            for failure in failures {
                lines.append("- `\(failure.caseID)`\(failure.trial > 1 ? " #\(failure.trial)" : ""): \(failure.failureReasons.joined(separator: "; ")). Review image `review/\(failure.caseID).png`.")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func finish(withError errorMessage: String?) {
        if let errorMessage { print("Error: \(errorMessage)") }
        NSApp.terminate(nil)
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

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let evalController = EvalController()
    application.delegate = evalController
    application.run()
}
