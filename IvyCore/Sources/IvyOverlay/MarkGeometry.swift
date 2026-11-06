import AppKit
import IvyCore

/// How every mark looks, in one place.
public enum MarkStyle {
    // A bright warm yellow. A stroke at least this bright, outlined in near-black, keeps one of
    // the two at 3:1 contrast or better on any background, so marks show up on any screen.
    public static let strokeRed = 1.0
    public static let strokeGreen = 0.788
    public static let strokeBlue = 0.235
    public static let strokeWidth: CGFloat = 4
    /// Drawn behind the stroke, so it shows 2 points of outline on each side.
    public static let outlineWidth: CGFloat = 8
    public static let outlineOpacity: CGFloat = 0.9
    /// Space left between a mark and what it points at, so a mark never covers it.
    public static let gapFromTarget: CGFloat = 6
    /// A highlight sits over the text, so it stays faint enough to read through.
    public static let highlightFillOpacity: CGFloat = 0.25
    public static let arrowLength: CGFloat = 80
    public static let arrowheadLength: CGFloat = 16
    public static let labelFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    public static let labelPadding = CGSize(width: 10, height: 5)
    /// Marks keep this far from the screen's edges where they can.
    public static let screenEdgeMargin: CGFloat = 8

    public static var strokeColor: CGColor { CGColor(srgbRed: strokeRed, green: strokeGreen, blue: strokeBlue, alpha: 1) }
    public static var outlineColor: CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: outlineOpacity) }

    /// WCAG relative luminance of an sRGB colour, from 0 for black to 1 for white.
    public static func relativeLuminance(_ color: (red: Double, green: Double, blue: Double)) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG contrast ratio, from 1 for identical colours to 21 for black on white.
    public static func contrastRatio(_ first: (red: Double, green: Double, blue: Double), _ second: (red: Double, green: Double, blue: Double)) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
    }
}

/// The shape of one mark, in the overlay's coordinates: points, with Y counting up from the bottom.
public struct MarkShape {
    public var strokePath: CGPath
    public var fillRect: CGRect?
    public var labelFrame: CGRect?
    public var arrowTip: CGPoint?
    public var arrowTail: CGPoint?
}

/// Works out where each kind of mark goes around its target. The rule for all of them is
/// that a mark never covers what it points at.
public enum MarkGeometry {
    public static func shape(for kind: MarkKind, targetRect: CGRect, visibleBounds: CGRect, labelText: String?) -> MarkShape {
        switch kind {
        case .circle: return circleShape(around: targetRect)
        case .underline: return underlineShape(below: targetRect, visibleBounds: visibleBounds)
        case .highlight: return highlightShape(over: targetRect)
        case .arrow: return arrowShape(pointingAt: targetRect, visibleBounds: visibleBounds)
        case .label: return labelShape(near: targetRect, visibleBounds: visibleBounds, labelText: labelText ?? "")
        }
    }

    /// An ellipse that fits exactly through a rectangle's corners is √2 times its size, so
    /// scaling by that, then adding the gap and half the outline, keeps the whole outline outside.
    private static func circleShape(around targetRect: CGRect) -> MarkShape {
        let clearance = MarkStyle.gapFromTarget + MarkStyle.outlineWidth / 2
        let horizontalRadius = targetRect.width / 2 * 2.0.squareRoot() + clearance
        let verticalRadius = targetRect.height / 2 * 2.0.squareRoot() + clearance
        let ellipseRect = CGRect(x: targetRect.midX - horizontalRadius, y: targetRect.midY - verticalRadius, width: horizontalRadius * 2, height: verticalRadius * 2)
        return MarkShape(strokePath: CGPath(ellipseIn: ellipseRect, transform: nil))
    }

    private static func underlineShape(below targetRect: CGRect, visibleBounds: CGRect) -> MarkShape {
        let clearance = MarkStyle.gapFromTarget / 2 + MarkStyle.outlineWidth / 2
        var lineY = targetRect.minY - clearance
        // Text at the very bottom of the screen has no room below, so the line goes above it.
        if lineY - MarkStyle.outlineWidth / 2 < visibleBounds.minY {
            lineY = targetRect.maxY + clearance
        }
        let linePath = CGMutablePath()
        linePath.move(to: CGPoint(x: targetRect.minX, y: lineY))
        linePath.addLine(to: CGPoint(x: targetRect.maxX, y: lineY))
        return MarkShape(strokePath: linePath)
    }

    private static func highlightShape(over targetRect: CGRect) -> MarkShape {
        let highlightRect = targetRect.insetBy(dx: -4, dy: -3)
        return MarkShape(strokePath: CGPath(roundedRect: highlightRect, cornerWidth: 4, cornerHeight: 4, transform: nil), fillRect: highlightRect)
    }

    /// The arrow comes in from the side facing the middle of the screen, where there's room,
    /// and its tip stops at the gap around the target.
    private static func arrowShape(pointingAt targetRect: CGRect, visibleBounds: CGRect) -> MarkShape {
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        var directionX = targetCenter.x - visibleBounds.midX
        var directionY = targetCenter.y - visibleBounds.midY
        var directionLength = hypot(directionX, directionY)
        if directionLength < 1 {
            // A target in the middle: come in from the upper left.
            directionX = 1
            directionY = -1
            directionLength = 2.0.squareRoot()
        }
        let unitX = directionX / directionLength
        let unitY = directionY / directionLength

        // Walk back from the target's center to the edge of its gap.
        let halfWidthWithGap = targetRect.width / 2 + MarkStyle.gapFromTarget
        let halfHeightWithGap = targetRect.height / 2 + MarkStyle.gapFromTarget
        let distanceToHorizontalEdge = abs(unitX) > 0.0001 ? halfWidthWithGap / abs(unitX) : .infinity
        let distanceToVerticalEdge = abs(unitY) > 0.0001 ? halfHeightWithGap / abs(unitY) : .infinity
        let distanceToGapEdge = min(distanceToHorizontalEdge, distanceToVerticalEdge)
        let arrowTip = CGPoint(x: targetCenter.x - unitX * distanceToGapEdge, y: targetCenter.y - unitY * distanceToGapEdge)

        let safeArea = visibleBounds.insetBy(dx: MarkStyle.screenEdgeMargin, dy: MarkStyle.screenEdgeMargin)
        let arrowTail = CGPoint(
            x: min(max(arrowTip.x - unitX * MarkStyle.arrowLength, safeArea.minX), safeArea.maxX),
            y: min(max(arrowTip.y - unitY * MarkStyle.arrowLength, safeArea.minY), safeArea.maxY)
        )

        let arrowPath = CGMutablePath()
        arrowPath.move(to: arrowTail)
        arrowPath.addLine(to: arrowTip)
        let shaftAngle = atan2(arrowTip.y - arrowTail.y, arrowTip.x - arrowTail.x)
        let barbSpread = CGFloat.pi / 6
        for barbAngle in [shaftAngle + .pi - barbSpread, shaftAngle + .pi + barbSpread] {
            arrowPath.move(to: CGPoint(x: arrowTip.x + cos(barbAngle) * MarkStyle.arrowheadLength, y: arrowTip.y + sin(barbAngle) * MarkStyle.arrowheadLength))
            arrowPath.addLine(to: arrowTip)
        }
        return MarkShape(strokePath: arrowPath, arrowTip: arrowTip, arrowTail: arrowTail)
    }

    /// Above the target if there's room, otherwise below, and always on screen.
    private static func labelShape(near targetRect: CGRect, visibleBounds: CGRect, labelText: String) -> MarkShape {
        let textSize = (labelText as NSString).size(withAttributes: [.font: MarkStyle.labelFont])
        let labelSize = CGSize(width: ceil(textSize.width) + MarkStyle.labelPadding.width * 2, height: ceil(textSize.height) + MarkStyle.labelPadding.height * 2)
        let safeArea = visibleBounds.insetBy(dx: MarkStyle.screenEdgeMargin, dy: MarkStyle.screenEdgeMargin)

        var labelY = targetRect.maxY + MarkStyle.gapFromTarget
        if labelY + labelSize.height > safeArea.maxY {
            labelY = targetRect.minY - MarkStyle.gapFromTarget - labelSize.height
        }
        let labelX = min(max(targetRect.midX - labelSize.width / 2, safeArea.minX), safeArea.maxX - labelSize.width)
        labelY = min(max(labelY, safeArea.minY), safeArea.maxY - labelSize.height)
        let labelFrame = CGRect(origin: CGPoint(x: labelX, y: labelY), size: labelSize)
        return MarkShape(strokePath: CGPath(roundedRect: labelFrame, cornerWidth: labelSize.height / 2, cornerHeight: labelSize.height / 2, transform: nil), labelFrame: labelFrame)
    }
}
