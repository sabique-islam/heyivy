import AppKit
import IvyCore
import QuartzCore
import Testing
@testable import IvyOverlay

private let visibleBounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

/// Wide text, a tall narrow control, a small icon, and targets hugging each edge.
private let sampleTargets: [CGRect] = [
    CGRect(x: 600, y: 400, width: 320, height: 22),
    CGRect(x: 700, y: 300, width: 30, height: 120),
    CGRect(x: 100, y: 100, width: 16, height: 16),
    CGRect(x: 2, y: 480, width: 80, height: 20),
    CGRect(x: 1430, y: 480, width: 80, height: 20),
    CGRect(x: 700, y: 2, width: 80, height: 20),
    CGRect(x: 700, y: 960, width: 80, height: 20),
    CGRect(x: 1, y: 1, width: 40, height: 18),
]

@Suite struct MarkGeometryTests {
    @Test(arguments: sampleTargets)
    func aCircleNeverCrossesWhatItPointsAt(target: CGRect) {
        let shape = MarkGeometry.shape(for: .circle, targetRect: target, visibleBounds: visibleBounds, labelText: nil)
        let ellipseRect = shape.strokePath.boundingBoxOfPath
        // The inside edge of the outline must still enclose every corner of the target.
        let innerHorizontalRadius = ellipseRect.width / 2 - MarkStyle.outlineWidth / 2
        let innerVerticalRadius = ellipseRect.height / 2 - MarkStyle.outlineWidth / 2
        for corner in [CGPoint(x: target.minX, y: target.minY), CGPoint(x: target.maxX, y: target.minY), CGPoint(x: target.minX, y: target.maxY), CGPoint(x: target.maxX, y: target.maxY)] {
            let horizontalShare = (corner.x - ellipseRect.midX) / innerHorizontalRadius
            let verticalShare = (corner.y - ellipseRect.midY) / innerVerticalRadius
            #expect(horizontalShare * horizontalShare + verticalShare * verticalShare <= 1)
        }
    }

    @Test(arguments: sampleTargets)
    func anUnderlineSitsBelowTheTextWithoutTouchingIt(target: CGRect) {
        let shape = MarkGeometry.shape(for: .underline, targetRect: target, visibleBounds: visibleBounds, labelText: nil)
        let lineBounds = shape.strokePath.boundingBoxOfPath
        // AppKit counts Y from the bottom, so below means a smaller Y. With no room below,
        // the line goes just above instead, still clear of the text.
        let sitsBelow = lineBounds.maxY + MarkStyle.outlineWidth / 2 <= target.minY + 0.001
        let sitsAboveForLackOfRoom = lineBounds.minY - MarkStyle.outlineWidth / 2 >= target.maxY - 0.001
        #expect(sitsBelow || sitsAboveForLackOfRoom)
        #expect(lineBounds.minY - MarkStyle.outlineWidth / 2 >= visibleBounds.minY - 0.001)
        #expect(abs(lineBounds.minX - target.minX) < 0.001 && abs(lineBounds.maxX - target.maxX) < 0.001)
    }

    @Test(arguments: sampleTargets)
    func aHighlightLeavesTheTextReadable(target: CGRect) {
        let shape = MarkGeometry.shape(for: .highlight, targetRect: target, visibleBounds: visibleBounds, labelText: nil)
        #expect(shape.fillRect?.contains(target) == true)
        #expect(MarkStyle.highlightFillOpacity <= 0.3)
    }

    @Test(arguments: sampleTargets)
    func anArrowStopsShortOfItsTargetAndStaysOnScreen(target: CGRect) {
        let shape = MarkGeometry.shape(for: .arrow, targetRect: target, visibleBounds: visibleBounds, labelText: nil)
        guard let arrowTip = shape.arrowTip, let arrowTail = shape.arrowTail else {
            Issue.record("an arrow needs a tip and a tail")
            return
        }
        #expect(!target.insetBy(dx: -MarkStyle.gapFromTarget + 0.5, dy: -MarkStyle.gapFromTarget + 0.5).contains(arrowTip))
        #expect(visibleBounds.contains(arrowTail))
        // The arrow points towards the target: the tip is closer to it than the tail.
        let targetCenter = CGPoint(x: target.midX, y: target.midY)
        #expect(hypot(arrowTip.x - targetCenter.x, arrowTip.y - targetCenter.y) < hypot(arrowTail.x - targetCenter.x, arrowTail.y - targetCenter.y))
    }

    @Test func anArrowTailIsPulledBackOnScreenWhenThereIsLittleRoom() {
        // A small visible area, like a narrow strip of screen, leaves no room for a full-length arrow.
        let smallBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let shape = MarkGeometry.shape(for: .arrow, targetRect: CGRect(x: 40, y: 40, width: 20, height: 20), visibleBounds: smallBounds, labelText: nil)
        #expect(shape.arrowTail.map { smallBounds.contains($0) } == true)
    }

    @Test(arguments: sampleTargets)
    func aLabelStaysOnScreenAndOffItsTarget(target: CGRect) {
        let shape = MarkGeometry.shape(for: .label, targetRect: target, visibleBounds: visibleBounds, labelText: "Save as PDF")
        guard let labelFrame = shape.labelFrame else {
            Issue.record("a label needs a frame")
            return
        }
        #expect(visibleBounds.contains(labelFrame))
        #expect(!labelFrame.intersects(target))
    }
}

@Suite struct MarkReadabilityTests {
    /// Backgrounds a mark has to show up on, from screens people actually look at.
    static let backgrounds: [(name: String, red: Double, green: Double, blue: Double)] = {
        var colors: [(String, Double, Double, Double)] = [
            ("white", 1, 1, 1), ("black", 0, 0, 0), ("red", 1, 0, 0), ("green", 0, 0.8, 0), ("blue", 0, 0, 1),
            ("cyan", 0, 1, 1), ("magenta", 1, 0, 1), ("yellow", 1, 1, 0), ("amber", 1, 0.7, 0), ("navy", 0, 0, 0.3),
            ("the mark's own colour", MarkStyle.strokeRed, MarkStyle.strokeGreen, MarkStyle.strokeBlue),
        ]
        for grayStep in 0...20 {
            let grayLevel = Double(grayStep) / 20
            colors.append(("gray \(grayStep)", grayLevel, grayLevel, grayLevel))
        }
        return colors
    }()

    @Test func onEveryBackgroundEitherTheStrokeOrItsOutlineStandsOut() {
        // WCAG asks for 3:1 for graphics that carry meaning, which marks do.
        for background in Self.backgrounds {
            let strokeContrast = MarkStyle.contrastRatio(
                (MarkStyle.strokeRed, MarkStyle.strokeGreen, MarkStyle.strokeBlue),
                (background.red, background.green, background.blue)
            )
            let outlineContrast = MarkStyle.contrastRatio((0, 0, 0), (background.red, background.green, background.blue))
            #expect(max(strokeContrast, outlineContrast) >= 3, "\(background.name)")
        }
    }

    @Test func theStrokeIsBrightEnoughThatNoBackgroundDefeatsBothColours() {
        // A stroke this bright, outlined in black, always has one of the two at 3:1 or more.
        #expect(MarkStyle.relativeLuminance((MarkStyle.strokeRed, MarkStyle.strokeGreen, MarkStyle.strokeBlue)) >= 0.4)
    }

    @Test @MainActor func theOutlineIsReallyDrawnBehindTheStroke() throws {
        let target = CGRect(x: 40, y: 50, width: 120, height: 20)
        let shape = MarkGeometry.shape(for: .underline, targetRect: target, visibleBounds: CGRect(x: 0, y: 0, width: 200, height: 120), labelText: nil)
        let markLayer = MarkLayer(kind: .underline, shape: shape, labelText: nil, contentsScale: 1)
        markLayer.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        markLayer.appear(animated: false)

        let pixels = try renderOnWhite(markLayer, width: 200, height: 120)
        let lineY = Int(shape.strokePath.boundingBoxOfPath.midY.rounded())
        // One pixel past the stroke's edge is outline only.
        let strokeCenter = pixels.color(x: 100, y: lineY)
        let outlineBand = pixels.color(x: 100, y: lineY - Int(MarkStyle.strokeWidth / 2) - 1)
        #expect(abs(strokeCenter.red - MarkStyle.strokeRed) < 0.08 && abs(strokeCenter.green - MarkStyle.strokeGreen) < 0.08)
        #expect(outlineBand.red < 0.25 && outlineBand.green < 0.25 && outlineBand.blue < 0.25)
    }
}

@Suite struct MarkAnimationTests {
    @Test @MainActor func marksDrawThemselvesInWhenMotionIsAllowed() {
        let shape = MarkGeometry.shape(for: .circle, targetRect: CGRect(x: 50, y: 50, width: 80, height: 20), visibleBounds: visibleBounds, labelText: nil)
        let markLayer = MarkLayer(kind: .circle, shape: shape, labelText: nil, contentsScale: 2)
        markLayer.appear(animated: true)
        #expect(markLayer.strokeLayer.animation(forKey: MarkLayer.drawInAnimationKey) != nil)
    }

    @Test @MainActor func withReducedMotionMarksAppearAtOnce() {
        let shape = MarkGeometry.shape(for: .circle, targetRect: CGRect(x: 50, y: 50, width: 80, height: 20), visibleBounds: visibleBounds, labelText: nil)
        let markLayer = MarkLayer(kind: .circle, shape: shape, labelText: nil, contentsScale: 2)
        markLayer.appear(animated: false)
        #expect(markLayer.strokeLayer.animationKeys() == nil)
        #expect(markLayer.strokeLayer.strokeEnd == 1)
        #expect(markLayer.opacity == 1)
    }
}

// MARK: - Rendering helper

private struct RenderedPixels {
    let bytes: [UInt8]
    let width: Int
    let height: Int

    /// Y counts from the bottom, like the layer it came from.
    func color(x: Int, y: Int) -> (red: Double, green: Double, blue: Double) {
        let rowFromTop = height - 1 - y
        let offset = (rowFromTop * width + x) * 4
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255)
    }
}

@MainActor
private func renderOnWhite(_ layer: CALayer, width: Int, height: Int) throws -> RenderedPixels {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.featureUnsupported) }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        layer.render(in: context)
    }
    return RenderedPixels(bytes: bytes, width: width, height: height)
}
