import CoreGraphics
import Foundation

/// A small grayscale copy of a screen, for telling whether the content under a mark changed.
/// Rows run from the top, and values from 0 for black to 1 for white.
public struct GrayscaleImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "A grayscale image needs one value per pixel.")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func value(atX x: Int, y: Int) -> Float {
        pixels[y * width + x]
    }
}

/// Decides whether the screen under a mark still shows what the mark was drawn on.
///
/// It compares the structure of the region, not its exact pixels, so it shrugs off what
/// doesn't move the content: a hover highlight that brightens the background, a blinking
/// caret, compression noise. What it catches is the content moving or being replaced, as
/// when the user scrolls or switches tabs, because then the pattern of light and dark in the
/// region no longer lines up with the original.
public enum ScreenRegionComparison {
    /// Below this correlation between the original and current region, the content has moved.
    public static let minimumCorrelationForUnchanged = 0.5
    /// A region whose brightness varies less than this is flat, like empty space, where
    /// correlation means nothing.
    public static let flatRegionStandardDeviation = 0.03
    /// For flat regions, a brightness change bigger than this means something else is there.
    public static let largestBrightnessShiftForUnchangedFlatRegion = 0.15
    /// Regions with fewer usable pixels than this can't be judged, so they count as unchanged.
    public static let fewestPixelsToJudge = 8

    /// `region` and `excludedRegions` are in the images' pixels, with the origin at the top
    /// left. Pixels inside an excluded region, like where the pointer was, are ignored.
    public static func regionHasChanged(
        baseline: GrayscaleImage,
        live: GrayscaleImage,
        region: CGRect,
        excludedRegions: [CGRect] = []
    ) -> Bool {
        // Images of different sizes come from a display change, which cancels the lesson anyway.
        guard baseline.width == live.width, baseline.height == live.height else { return false }
        let imageBounds = CGRect(x: 0, y: 0, width: baseline.width, height: baseline.height)
        let clippedRegion = region.intersection(imageBounds)
        guard !clippedRegion.isNull, !clippedRegion.isEmpty else { return false }

        var baselineValues: [Double] = []
        var liveValues: [Double] = []
        for y in Int(clippedRegion.minY.rounded(.down))..<Int(clippedRegion.maxY.rounded(.up)) {
            for x in Int(clippedRegion.minX.rounded(.down))..<Int(clippedRegion.maxX.rounded(.up)) {
                let pixelCenter = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if excludedRegions.contains(where: { $0.contains(pixelCenter) }) { continue }
                baselineValues.append(Double(baseline.value(atX: x, y: y)))
                liveValues.append(Double(live.value(atX: x, y: y)))
            }
        }
        guard baselineValues.count >= fewestPixelsToJudge else { return false }

        let pixelCount = Double(baselineValues.count)
        let baselineMean = baselineValues.reduce(0, +) / pixelCount
        let liveMean = liveValues.reduce(0, +) / pixelCount
        var baselineVariance = 0.0
        var liveVariance = 0.0
        var covariance = 0.0
        for (baselineValue, liveValue) in zip(baselineValues, liveValues) {
            let baselineOffset = baselineValue - baselineMean
            let liveOffset = liveValue - liveMean
            baselineVariance += baselineOffset * baselineOffset
            liveVariance += liveOffset * liveOffset
            covariance += baselineOffset * liveOffset
        }
        let baselineDeviation = (baselineVariance / pixelCount).squareRoot()
        let liveDeviation = (liveVariance / pixelCount).squareRoot()

        let baselineIsFlat = baselineDeviation < flatRegionStandardDeviation
        let liveIsFlat = liveDeviation < flatRegionStandardDeviation
        if baselineIsFlat && liveIsFlat {
            return abs(baselineMean - liveMean) > largestBrightnessShiftForUnchangedFlatRegion
        }
        // Content appeared where there was none, or disappeared.
        if baselineIsFlat != liveIsFlat { return true }

        let correlation = covariance / (baselineVariance.squareRoot() * liveVariance.squareRoot())
        return correlation < minimumCorrelationForUnchanged
    }
}

/// Counts how many samples in a row each watched mark's region has looked changed, so one
/// odd frame, like a menu flashing past, doesn't fade a mark.
public struct MarkChangeTracker: Sendable {
    public let changedSamplesNeeded: Int
    private var consecutiveChangedSamples: [Int: Int] = [:]

    public init(changedSamplesNeeded: Int = 2) {
        self.changedSamplesNeeded = changedSamplesNeeded
    }

    /// Records one sample for a mark. True the first time it's been changed long enough.
    public mutating func record(markID: Int, regionHasChanged: Bool) -> Bool {
        guard regionHasChanged else {
            consecutiveChangedSamples[markID] = 0
            return false
        }
        let changedSamples = (consecutiveChangedSamples[markID] ?? 0) + 1
        consecutiveChangedSamples[markID] = changedSamples
        return changedSamples == changedSamplesNeeded
    }

    public mutating func forget(markID: Int) {
        consecutiveChangedSamples[markID] = nil
    }
}
