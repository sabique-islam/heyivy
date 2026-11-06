import AppKit
import IvyCore
import IvyOverlay
import ScreenCaptureKit

// MarkOverlayLab: draws marks from a script file over a test card on every screen, with no
// network (drawing plan, D3). It checks what can be checked without a person watching:
//
//   - marks draw over a full-screen app, on every screen
//   - Ivy's own screen capture leaves them out, while a normal capture shows them
//   - the overlay uses next to no CPU while marks sit still
//
//   --script PATH       Marks to draw. Default: Examples/overlay-demo.json
//   --reduce-motion     Draw without animation, as the Reduce Motion setting does
//   --no-full-screen    Keep the test card in a normal window
//   --check-capture     Capture the screen to check marks are left out. Needs Screen Recording.
//   --result PATH       Where to write the JSON result
//
// Run it with scripts/mark-overlay-lab.sh.

struct LabOptions {
    var scriptPath = "Examples/overlay-demo.json"
    var reduceMotion = false
    var useFullScreen = true
    var checkCapture = false
    var resultPath = FileManager.default.temporaryDirectory.appendingPathComponent("mark-overlay-lab-result.json").path

    init(arguments: [String]) {
        var argumentIndex = 1
        while argumentIndex < arguments.count {
            let nextValue = argumentIndex + 1 < arguments.count ? arguments[argumentIndex + 1] : ""
            switch arguments[argumentIndex] {
            case "--script": scriptPath = nextValue; argumentIndex += 1
            case "--result": resultPath = nextValue; argumentIndex += 1
            case "--reduce-motion": reduceMotion = true
            case "--no-full-screen": useFullScreen = false
            case "--check-capture": checkCapture = true
            default: break
            }
            argumentIndex += 1
        }
    }
}

struct ScriptedMark: Decodable {
    var atSeconds: Double
    var tile: Int
    var kind: String
    var labelText: String?
}

struct MarkScript: Decodable {
    var marks: [ScriptedMark]
}

/// Twelve backgrounds a mark must show up on, each with a word to point at. None of them
/// uses the marks' own yellow, so the capture check can count mark pixels by colour.
struct TestCardTile {
    let backgroundName: String
    let word: String
    let draw: (CGRect) -> Void

    static let all: [TestCardTile] = [
        solid("white", "Export as PDF", .white),
        solid("black", "fibonacci(n)", .black),
        solid("mid gray", "Settings", NSColor(white: 0.5, alpha: 1)),
        solid("dark gray", "total", NSColor(white: 0.18, alpha: 1)),
        solid("light gray", "cache", NSColor(white: 0.85, alpha: 1)),
        solid("red", "x − 1", .systemRed),
        solid("blue", "Save", NSColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1)),
        solid("green", "def main():", NSColor(srgbRed: 0.1, green: 0.65, blue: 0.25, alpha: 1)),
        solid("amber", "Revenue", NSColor(srgbRed: 1, green: 0.62, blue: 0, alpha: 1)),
        solid("magenta", "Σ λ ≤ 3", NSColor(srgbRed: 0.85, green: 0.1, blue: 0.75, alpha: 1)),
        TestCardTile(backgroundName: "photo-like gradient", word: "Q3 2026") { tileRect in
            let colors = [NSColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.2, green: 0.6, blue: 0.65, alpha: 1), NSColor(srgbRed: 0.85, green: 0.85, blue: 0.95, alpha: 1)]
            NSGradient(colors: colors)?.draw(in: tileRect, angle: 35)
        },
        TestCardTile(backgroundName: "busy noise", word: "border") { tileRect in
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<1500 {
                NSColor(white: Double.random(in: 0...1, using: &generator), alpha: 1).setFill()
                NSRect(x: tileRect.minX + Double.random(in: 0..<tileRect.width, using: &generator), y: tileRect.minY + Double.random(in: 0..<tileRect.height, using: &generator), width: 10, height: 10).fill()
            }
        },
    ]

    static func solid(_ backgroundName: String, _ word: String, _ color: NSColor) -> TestCardTile {
        TestCardTile(backgroundName: backgroundName, word: word) { tileRect in
            color.setFill()
            tileRect.fill()
        }
    }

    static let columnCount = 4
    static let rowCount = 3
    static let wordFont = NSFont.systemFont(ofSize: 30, weight: .medium)

    static func tileRect(index: Int, in bounds: CGRect) -> CGRect {
        let tileWidth = bounds.width / Double(columnCount)
        let tileHeight = bounds.height / Double(rowCount)
        let column = index % columnCount
        let rowFromTop = index / columnCount
        return CGRect(x: bounds.minX + Double(column) * tileWidth, y: bounds.maxY - Double(rowFromTop + 1) * tileHeight, width: tileWidth, height: tileHeight)
    }

    /// Where the word sits in its tile. The lab knows this exactly, so no text recognition is needed.
    static func wordRect(index: Int, in bounds: CGRect) -> CGRect {
        let tileRect = tileRect(index: index, in: bounds)
        let wordSize = (all[index].word as NSString).size(withAttributes: [.font: wordFont])
        return CGRect(x: tileRect.midX - wordSize.width / 2, y: tileRect.midY - wordSize.height / 2, width: wordSize.width, height: wordSize.height)
    }
}

final class TestCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        for (tileIndex, tile) in TestCardTile.all.enumerated() {
            let tileRect = TestCardTile.tileRect(index: tileIndex, in: bounds)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: tileRect).addClip()
            tile.draw(tileRect)
            NSGraphicsContext.restoreGraphicsState()

            let wordRect = TestCardTile.wordRect(index: tileIndex, in: bounds)
            // A plate behind the word keeps it readable on the noisy tiles, like real UI text.
            NSColor(white: 0, alpha: tileIndex == 11 ? 0.55 : 0).setFill()
            wordRect.insetBy(dx: -4, dy: -2).fill()
            let isLightTile = [0, 2, 4, 8].contains(tileIndex)
            let wordColor: NSColor = isLightTile ? .black : .white
            (tile.word as NSString).draw(in: wordRect, withAttributes: [.font: TestCardTile.wordFont, .foregroundColor: wordColor])
        }
    }
}

@MainActor
final class LabController: NSObject, NSApplicationDelegate {
    private let options = LabOptions(arguments: CommandLine.arguments)
    private let markOverlay = MarkOverlayController()
    private var testCardWindows: [NSWindow] = []
    private var result: [String: Any] = [:]
    private var shownMarkIDsInOrder: [Int] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        markOverlay.forceReducedMotion = options.reduceMotion
        result["screens"] = NSScreen.screens.map { screen -> [String: Any] in
            ["pointSize": "\(Int(screen.frame.width))x\(Int(screen.frame.height))", "scale": screen.backingScaleFactor, "origin": "\(Int(screen.frame.minX)),\(Int(screen.frame.minY))"]
        }
        result["reducedMotion"] = markOverlay.shouldReduceMotion

        let script: MarkScript
        do {
            script = try JSONDecoder().decode(MarkScript.self, from: Data(contentsOf: URL(fileURLWithPath: options.scriptPath)))
        } catch {
            finish(withError: "Couldn't read the script at \(options.scriptPath): \(error.localizedDescription)")
            return
        }

        for screen in NSScreen.screens {
            let cardWindow = NSWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false, screen: screen)
            cardWindow.title = "Ivy mark overlay lab"
            cardWindow.collectionBehavior = [.fullScreenPrimary]
            cardWindow.contentView = TestCardView()
            cardWindow.setFrame(screen.visibleFrame, display: true)
            cardWindow.makeKeyAndOrderFront(nil)
            testCardWindows.append(cardWindow)
        }
        NSApp.activate(ignoringOtherApps: true)
        // macOS ignores a full-screen request from an app that isn't active yet.
        if options.useFullScreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                for cardWindow in self.testCardWindows { cardWindow.toggleFullScreen(nil) }
            }
        }

        // Full screen takes a moment to settle, and tile positions depend on the final size.
        let settleSeconds = options.useFullScreen ? 3.0 : 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) { self.play(script) }
    }

    private func play(_ script: MarkScript) {
        result["testCardIsFullScreen"] = testCardWindows.map { $0.styleMask.contains(.fullScreen) }
        var nextMarkID = 0
        for (screenIndex, cardWindow) in testCardWindows.enumerated() {
            guard let cardView = cardWindow.contentView else { continue }
            for scriptedMark in script.marks {
                guard let kind = MarkKind(rawValue: scriptedMark.kind), TestCardTile.all.indices.contains(scriptedMark.tile) else { continue }
                let markID = nextMarkID
                nextMarkID += 1
                let wordRectInWindow = cardView.convert(TestCardTile.wordRect(index: scriptedMark.tile, in: cardView.bounds), to: nil)
                let wordRectGlobal = cardWindow.convertToScreen(wordRectInWindow)
                DispatchQueue.main.asyncAfter(deadline: .now() + scriptedMark.atSeconds) {
                    self.markOverlay.show(markID: markID, kind: kind, globalRect: wordRectGlobal, labelText: scriptedMark.labelText)
                    self.shownMarkIDsInOrder.append(markID)
                    // MarkTimeline enforces this in the app. The lab does the same by hand.
                    let marksPerScreen = 5 * self.testCardWindows.count
                    while self.shownMarkIDsInOrder.count > marksPerScreen {
                        self.markOverlay.fade(markID: self.shownMarkIDsInOrder.removeFirst())
                    }
                }
                _ = screenIndex
            }
        }

        let lastMarkSeconds = script.marks.map(\.atSeconds).max() ?? 0
        if options.checkCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + min(lastMarkSeconds, 3.0) + 0.6) {
                Task { @MainActor in await self.checkScreenCapture() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + lastMarkSeconds + 1.0) { self.measureIdleCPU() }
    }

    /// With every mark drawn and nothing moving, the overlay should cost almost nothing.
    private func measureIdleCPU() {
        result["marksOnScreenWhileIdle"] = markOverlay.shownMarkCount
        let cpuSecondsAtStart = processCPUSeconds()
        let wallSecondsAtStart = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let cpuSecondsUsed = self.processCPUSeconds() - cpuSecondsAtStart
            let wallSecondsElapsed = ProcessInfo.processInfo.systemUptime - wallSecondsAtStart
            self.result["idleCPUPercentOfOneCore"] = (cpuSecondsUsed / wallSecondsElapsed * 1000).rounded() / 10
            self.markOverlay.fadeAll(afterSeconds: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + MarkOverlayController.fadeDurationSeconds + 0.4) {
                self.result["marksLeftAfterFadeAll"] = self.markOverlay.shownMarkCount
                self.finish(withError: nil)
            }
        }
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let userSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let systemSeconds = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return userSeconds + systemSeconds
    }

    /// Captures each display twice: the way Ivy does, leaving out the overlay windows, and
    /// with nothing left out. Mark-coloured pixels should appear only in the second.
    @MainActor
    private func checkScreenCapture() async {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let overlayWindowNumbers = Set(markOverlay.overlayWindowNumbers)
            let overlayWindows = shareableContent.windows.filter { overlayWindowNumbers.contains(Int($0.windowID)) }
            result["overlayWindowsFoundForCapture"] = overlayWindows.count
            var displayReports: [[String: Any]] = []
            for display in shareableContent.displays {
                let withoutOverlay = try await captureMarkColoredPixels(display: display, excludingWindows: overlayWindows)
                let withEverything = try await captureMarkColoredPixels(display: display, excludingWindows: [])
                displayReports.append([
                    "display": display.displayID,
                    "markPixelsInIvysCapture": withoutOverlay,
                    "markPixelsInANormalCapture": withEverything,
                ])
            }
            result["captureCheck"] = displayReports
        } catch {
            result["captureCheck"] = "failed: \(error.localizedDescription). Screen Recording may not be allowed for the lab."
        }
    }

    private func captureMarkColoredPixels(display: SCDisplay, excludingWindows: [SCWindow]) async throws -> Int {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: excludingWindows), configuration: configuration)
        guard let pixelData = image.dataProvider?.data, let pixelBytes = CFDataGetBytePtr(pixelData) else { return -1 }
        let bytesPerPixel = image.bitsPerPixel / 8
        let isBlueFirst = image.bitmapInfo.contains(.byteOrder32Little)
        var markColoredPixels = 0
        let tolerance = 0.07
        for row in stride(from: 0, to: image.height, by: 2) {
            for column in stride(from: 0, to: image.width, by: 2) {
                let offset = row * image.bytesPerRow + column * bytesPerPixel
                let red = Double(pixelBytes[offset + (isBlueFirst ? 2 : 0)]) / 255
                let green = Double(pixelBytes[offset + 1]) / 255
                let blue = Double(pixelBytes[offset + (isBlueFirst ? 0 : 2)]) / 255
                if abs(red - MarkStyle.strokeRed) < tolerance && abs(green - MarkStyle.strokeGreen) < tolerance && abs(blue - MarkStyle.strokeBlue) < tolerance {
                    markColoredPixels += 1
                }
            }
        }
        return markColoredPixels
    }

    private func finish(withError errorMessage: String?) {
        if let errorMessage { result["error"] = errorMessage }
        if let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: options.resultPath, contents: resultData)
        }
        markOverlay.clearAll(closingWindows: true)
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
