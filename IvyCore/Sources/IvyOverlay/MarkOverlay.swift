import AppKit
import IvyCore
import QuartzCore

/// One mark, drawn as its own Core Animation layers: a dark outline with the coloured stroke
/// on top. Animating the stroke runs in the window server, so the app does no work per frame.
public final class MarkLayer: CALayer {
    public static let drawInAnimationKey = "drawIn"
    static let drawInDurationSeconds = 0.35

    let kind: MarkKind
    let outlineLayer = CAShapeLayer()
    let strokeLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private var labelTextLayer: CATextLayer?

    public init(kind: MarkKind, shape: MarkShape, labelText: String?, contentsScale: CGFloat) {
        self.kind = kind
        super.init()
        self.contentsScale = contentsScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 0

        if let fillRect = shape.fillRect {
            fillLayer.path = CGPath(roundedRect: fillRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            fillLayer.fillColor = MarkStyle.strokeColor.copy(alpha: MarkStyle.highlightFillOpacity)
            fillLayer.strokeColor = nil
            addSublayer(fillLayer)
        }

        for (shapeLayer, lineWidth, color) in [(outlineLayer, MarkStyle.outlineWidth, MarkStyle.outlineColor), (strokeLayer, MarkStyle.strokeWidth, MarkStyle.strokeColor)] {
            shapeLayer.path = shape.strokePath
            shapeLayer.lineWidth = lineWidth
            shapeLayer.strokeColor = color
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            shapeLayer.contentsScale = contentsScale
            // A label is a solid dark pill, so its text is readable on anything.
            shapeLayer.fillColor = (kind == .label && shapeLayer === outlineLayer) ? MarkStyle.outlineColor : nil
            addSublayer(shapeLayer)
        }

        if kind == .label, let labelFrame = shape.labelFrame {
            let textLayer = CATextLayer()
            textLayer.string = labelText ?? ""
            textLayer.font = MarkStyle.labelFont
            textLayer.fontSize = MarkStyle.labelFont.pointSize
            textLayer.foregroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            textLayer.alignmentMode = .center
            textLayer.contentsScale = contentsScale
            textLayer.frame = labelFrame.insetBy(dx: MarkStyle.labelPadding.width, dy: MarkStyle.labelPadding.height)
            addSublayer(textLayer)
            labelTextLayer = textLayer
        }
        CATransaction.commit()
    }

    override init(layer: Any) {
        let otherMarkLayer = layer as? MarkLayer
        kind = otherMarkLayer?.kind ?? .circle
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("Mark layers are only made in code.")
    }

    public override var frame: CGRect {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sublayer in [fillLayer, outlineLayer, strokeLayer] { sublayer.frame = bounds }
            CATransaction.commit()
        }
    }

    /// Lines draw themselves in. Highlights and labels fade in. With reduced motion, all appear at once.
    public func appear(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 1
        CATransaction.commit()
        guard animated else { return }

        if kind == .highlight || kind == .label {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = Self.drawInDurationSeconds
            add(fadeIn, forKey: Self.drawInAnimationKey)
            return
        }
        for shapeLayer in [outlineLayer, strokeLayer] {
            let drawIn = CABasicAnimation(keyPath: "strokeEnd")
            drawIn.fromValue = 0
            drawIn.toValue = 1
            drawIn.duration = Self.drawInDurationSeconds
            drawIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shapeLayer.add(drawIn, forKey: Self.drawInAnimationKey)
        }
    }

    public func fadeOut(durationSeconds: Double, animated: Bool, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? durationSeconds : 0)
        CATransaction.setDisableActions(!animated)
        CATransaction.setCompletionBlock(completion)
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            fade.duration = durationSeconds
            add(fade, forKey: "fadeOut")
        }
        opacity = 0
        CATransaction.commit()
    }
}

/// A transparent window over one screen that holds that screen's marks. Clicks pass straight
/// through it, it never takes focus, and it shows on every Space and over full-screen apps.
final class MarkOverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let markHostView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        markHostView.wantsLayer = true
        contentView = markHostView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows, fades, and clears marks across every screen. It does the drawing only: when marks
/// appear and how many show at once are decided by `MarkTimeline`.
///
/// Windows exist only while they hold a mark, so an idle overlay costs nothing. Ivy's own
/// screen capture leaves these windows out, using `overlayWindowNumbers`, so marks never
/// end up in the screenshot Claude sees. Other apps, like screen sharing, can still see them.
@MainActor
public final class MarkOverlayController {
    private struct ShownMark {
        let layer: MarkLayer
        let screenNumber: CGDirectDisplayID
    }

    /// Set by the app or a test. The system's Reduce Motion setting is always respected too.
    public var forceReducedMotion = false
    private var overlayWindowsByScreenNumber: [CGDirectDisplayID: MarkOverlayWindow] = [:]
    private var shownMarksByID: [Int: ShownMark] = [:]
    private var pendingFadeAll: DispatchWorkItem?
    private var screenChangeObserver: NSObjectProtocol?

    public static let fadeDurationSeconds = 0.4

    public init() {
        // Display changes move everything, so marks are cleared rather than left in the wrong place.
        screenChangeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearAll(closingWindows: true) }
        }
    }

    public var shouldReduceMotion: Bool {
        forceReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public var overlayWindowNumbers: [Int] { overlayWindowsByScreenNumber.values.map(\.windowNumber) }
    public var shownMarkCount: Int { shownMarksByID.count }

    /// `globalRect` is in AppKit's global coordinates, as `CapturedScreenGeometry` produces.
    public func show(markID: Int, kind: MarkKind, globalRect: CGRect, labelText: String?) {
        pendingFadeAll?.cancel()
        guard let screen = screen(for: globalRect), let screenNumber = screen.displayNumber else { return }
        let overlayWindow = overlayWindow(for: screen, screenNumber: screenNumber)
        guard let hostLayer = overlayWindow.contentView?.layer else { return }

        let targetRectInWindow = globalRect.offsetBy(dx: -overlayWindow.frame.minX, dy: -overlayWindow.frame.minY)
        let shape = MarkGeometry.shape(for: kind, targetRect: targetRectInWindow, visibleBounds: hostLayer.bounds, labelText: labelText)
        let markLayer = MarkLayer(kind: kind, shape: shape, labelText: labelText, contentsScale: screen.backingScaleFactor)
        markLayer.frame = hostLayer.bounds
        hostLayer.addSublayer(markLayer)
        markLayer.appear(animated: !shouldReduceMotion)

        shownMarksByID[markID]?.layer.removeFromSuperlayer()
        shownMarksByID[markID] = ShownMark(layer: markLayer, screenNumber: screenNumber)
        overlayWindow.orderFrontRegardless()
    }

    public func fade(markID: Int) {
        guard let shownMark = shownMarksByID.removeValue(forKey: markID) else { return }
        shownMark.layer.fadeOut(durationSeconds: Self.fadeDurationSeconds, animated: !shouldReduceMotion) { [weak self] in
            MainActor.assumeIsolated {
                shownMark.layer.removeFromSuperlayer()
                self?.hideWindowsWithoutMarks()
            }
        }
    }

    /// After a lesson, marks stay a few seconds, then fade. A new mark cancels this.
    public func fadeAll(afterSeconds delaySeconds: Double) {
        pendingFadeAll?.cancel()
        let fadeAllWork = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for markID in Array(self.shownMarksByID.keys) { self.fade(markID: markID) }
            }
        }
        pendingFadeAll = fadeAllWork
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: fadeAllWork)
    }

    /// Immediately, with no animation. Used on interrupt, so stale marks vanish at once.
    public func clearAll(closingWindows: Bool = false) {
        pendingFadeAll?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shownMark in shownMarksByID.values { shownMark.layer.removeFromSuperlayer() }
        CATransaction.commit()
        shownMarksByID.removeAll()
        if closingWindows {
            for overlayWindow in overlayWindowsByScreenNumber.values { overlayWindow.close() }
            overlayWindowsByScreenNumber.removeAll()
        } else {
            hideWindowsWithoutMarks()
        }
    }

    private func hideWindowsWithoutMarks() {
        let screensWithMarks = Set(shownMarksByID.values.map(\.screenNumber))
        for (screenNumber, overlayWindow) in overlayWindowsByScreenNumber where !screensWithMarks.contains(screenNumber) {
            overlayWindow.orderOut(nil)
        }
    }

    private func overlayWindow(for screen: NSScreen, screenNumber: CGDirectDisplayID) -> MarkOverlayWindow {
        if let existingWindow = overlayWindowsByScreenNumber[screenNumber] { return existingWindow }
        let newWindow = MarkOverlayWindow(screen: screen)
        overlayWindowsByScreenNumber[screenNumber] = newWindow
        return newWindow
    }

    /// The screen holding the target's center, or failing that, the one it overlaps most.
    private func screen(for globalRect: CGRect) -> NSScreen? {
        let targetCenter = CGPoint(x: globalRect.midX, y: globalRect.midY)
        if let screenHoldingCenter = NSScreen.screens.first(where: { $0.frame.contains(targetCenter) }) { return screenHoldingCenter }
        return NSScreen.screens.max { first, second in
            let firstOverlap = first.frame.intersection(globalRect)
            let secondOverlap = second.frame.intersection(globalRect)
            return firstOverlap.width * firstOverlap.height < secondOverlap.width * secondOverlap.height
        }
    }
}

extension NSScreen {
    var displayNumber: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
