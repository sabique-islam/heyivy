import AppKit
import IvyCore
import ScreenCaptureKit

/// Watches the screen under each visible mark and reports when it no longer shows what the
/// mark was drawn on, as after a scroll, so the mark can fade instead of pointing at the
/// wrong thing. Marks don't follow content in the first version: if it moved, the mark goes.
///
/// It compares small grayscale copies of the screen with the one Claude saw, a few times a
/// second, only while marks are showing. Ivy's own windows, the marks included, are left
/// out of each capture, and so is the pointer. The pointer is in the original screenshot,
/// so the area around where it was is ignored.
@MainActor
public final class MarkStalenessWatcher {
    /// A mark whose content changed. Called once per mark.
    public var onMarkStale: ((Int) -> Void)?
    /// Another app came to the front, so every mark is stale.
    public var onFrontAppChanged: (() -> Void)?

    // About 7 samples a second and two changed samples in a row: a scroll fades its marks
    // within about 300 ms plus the capture time, and a single odd frame never does.
    private static let secondsBetweenSamples = 0.15
    private static let analysisWidthInPixels = 480
    /// Around a mark's target, so a change right at its edge counts.
    private static let regionPaddingInImagePixels = 6.0
    /// The pointer's size and then some, in screen points, centered where it was.
    private static let pointerAreaSizeInPoints = 48.0

    private let baselineImage: CGImage
    private let geometry: CapturedScreenGeometry
    private let pointerLocationInGlobalPoints: CGPoint?
    private var baselineGrayscale: GrayscaleImage?
    private var watchedRegionsInImagePixels: [Int: CGRect] = [:]
    private var changeTracker = MarkChangeTracker(changedSamplesNeeded: 2)
    private var samplingTask: Task<Void, Never>?
    private var frontAppObserver: NSObjectProtocol?
    private var captureFilter: SCContentFilter?
    private var hasGivenUp = false
    /// Nil leaves out all of Ivy's windows. A lab whose test card is its own window passes
    /// just the mark windows instead.
    private let windowNumbersToLeaveOut: [Int]?

    public init(baselineImage: CGImage, geometry: CapturedScreenGeometry, pointerLocationInGlobalPoints: CGPoint?, windowNumbersToLeaveOut: [Int]? = nil) {
        self.baselineImage = baselineImage
        self.geometry = geometry
        self.pointerLocationInGlobalPoints = pointerLocationInGlobalPoints
        self.windowNumbersToLeaveOut = windowNumbersToLeaveOut
        frontAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Ivy's own panel coming forward doesn't change what's under the marks.
            guard activatedApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, !self.watchedRegionsInImagePixels.isEmpty else { return }
                self.onFrontAppChanged?()
            }
        }
    }

    deinit {
        if let frontAppObserver { NSWorkspace.shared.notificationCenter.removeObserver(frontAppObserver) }
        samplingTask?.cancel()
    }

    public func watch(markID: Int, regionInImagePixels: CGRect) {
        guard !hasGivenUp else { return }
        watchedRegionsInImagePixels[markID] = regionInImagePixels.insetBy(dx: -Self.regionPaddingInImagePixels, dy: -Self.regionPaddingInImagePixels)
        startSamplingIfNeeded()
    }

    public func stopWatching(markID: Int) {
        watchedRegionsInImagePixels[markID] = nil
        changeTracker.forget(markID: markID)
        if watchedRegionsInImagePixels.isEmpty { stopSampling() }
    }

    public func stopAll() {
        watchedRegionsInImagePixels = [:]
        changeTracker = MarkChangeTracker(changedSamplesNeeded: 2)
        stopSampling()
    }

    private func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    private func startSamplingIfNeeded() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.takeOneSample()
                try? await Task.sleep(nanoseconds: UInt64(Self.secondsBetweenSamples * 1_000_000_000))
            }
        }
    }

    private var analysisHeightInPixels: Int {
        max(1, Int((Double(Self.analysisWidthInPixels) * geometry.imagePixelSize.height / geometry.imagePixelSize.width).rounded()))
    }

    private func takeOneSample() async {
        guard !watchedRegionsInImagePixels.isEmpty else { return }
        let analysisWidth = Self.analysisWidthInPixels
        let analysisHeight = analysisHeightInPixels
        if baselineGrayscale == nil {
            baselineGrayscale = Self.grayscale(of: baselineImage, width: analysisWidth, height: analysisHeight)
        }

        let liveImage: CGImage
        do {
            liveImage = try await captureLiveScreen(width: analysisWidth, height: analysisHeight)
        } catch {
            // Without Screen Recording, or if the display went away, marks just aren't watched.
            print("⚠️ MarkStalenessWatcher: can't sample the screen, so marks won't fade on changes: \(error)")
            hasGivenUp = true
            stopAll()
            return
        }
        guard !Task.isCancelled,
              let baselineGrayscale,
              let liveGrayscale = Self.grayscale(of: liveImage, width: analysisWidth, height: analysisHeight) else { return }

        let analysisPixelsPerImagePixel = Double(analysisWidth) / geometry.imagePixelSize.width
        let pointerAreaInAnalysisPixels = pointerAreaInImagePixels().map { Self.scaled($0, by: analysisPixelsPerImagePixel) }

        for (markID, regionInImagePixels) in watchedRegionsInImagePixels {
            let regionHasChanged = ScreenRegionComparison.regionHasChanged(
                baseline: baselineGrayscale,
                live: liveGrayscale,
                region: Self.scaled(regionInImagePixels, by: analysisPixelsPerImagePixel),
                excludedRegions: pointerAreaInAnalysisPixels.map { [$0] } ?? []
            )
            if changeTracker.record(markID: markID, regionHasChanged: regionHasChanged) {
                stopWatching(markID: markID)
                onMarkStale?(markID)
            }
        }
    }

    private func pointerAreaInImagePixels() -> CGRect? {
        guard let pointerLocationInGlobalPoints else { return nil }
        let halfSize = Self.pointerAreaSizeInPoints / 2
        let pointerAreaInGlobalPoints = CGRect(
            x: pointerLocationInGlobalPoints.x - halfSize,
            y: pointerLocationInGlobalPoints.y - halfSize,
            width: Self.pointerAreaSizeInPoints,
            height: Self.pointerAreaSizeInPoints
        )
        return geometry.imagePixelRect(fromGlobalRect: pointerAreaInGlobalPoints)
    }

    /// Captures the marks' display without Ivy's windows or the pointer. The filter excludes
    /// Ivy as an app, so mark windows opened after it was made are left out too.
    private func captureLiveScreen(width: Int, height: Int) async throws -> CGImage {
        if captureFilter == nil {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let displayID = displayID(),
                  let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
                throw MarkStalenessWatcherError.displayNotConnected
            }
            if let windowNumbersToLeaveOut {
                let windowsToLeaveOut = shareableContent.windows.filter { windowNumbersToLeaveOut.contains(Int($0.windowID)) }
                captureFilter = SCContentFilter(display: display, excludingWindows: windowsToLeaveOut)
            } else {
                let ivyApps = shareableContent.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                captureFilter = SCContentFilter(display: display, excludingApplications: ivyApps, exceptingWindows: [])
            }
        }
        guard let captureFilter else { throw CancellationError() }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: captureFilter, configuration: configuration)
    }

    private func displayID() -> CGDirectDisplayID? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let matchingScreen = NSScreen.screens.first { $0.frame == geometry.screenFrameInGlobalPoints }
        return (matchingScreen?.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value
    }

    private static func scaled(_ rect: CGRect, by factor: Double) -> CGRect {
        CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor)
    }

    /// Both images are shrunk the same way, by Core Graphics, so the original and each
    /// sample are compared like for like.
    static func grayscale(of image: CGImage, width: Int, height: Int) -> GrayscaleImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        // Core Graphics bitmaps start at the top row in memory, which is what GrayscaleImage expects.
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        let pixels = (0..<(width * height)).map { Float(bytes[$0]) / 255 }
        return GrayscaleImage(width: width, height: height, pixels: pixels)
    }
}

enum MarkStalenessWatcherError: Error {
    case displayNotConnected
}
