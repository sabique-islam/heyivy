import CoreGraphics
import Testing
@testable import IvyCore

private let imageWidth = 120
private let imageHeight = 80

/// Lines of "text": dark dashes of varying length on a light background, one every 8 rows.
private func textLikeScreen(scrolledUpByRows scrolledRows: Int = 0) -> GrayscaleImage {
    var pixels = [Float](repeating: 0.95, count: imageWidth * imageHeight)
    for y in 0..<imageHeight {
        let contentRow = y + scrolledRows
        guard contentRow % 8 < 3 else { continue }
        let lineNumber = contentRow / 8
        for x in 0..<imageWidth {
            // Each line has its own pattern of words and gaps, so lines don't look alike.
            let wordPosition = (x + lineNumber * 13) % (17 + lineNumber % 5)
            if wordPosition < 11 { pixels[y * imageWidth + x] = 0.1 }
        }
    }
    return GrayscaleImage(width: imageWidth, height: imageHeight, pixels: pixels)
}

private func transformed(_ image: GrayscaleImage, _ transform: (Float, Int) -> Float) -> GrayscaleImage {
    GrayscaleImage(width: image.width, height: image.height, pixels: image.pixels.enumerated().map { transform($0.element, $0.offset) })
}

private func flatScreen(brightness: Float) -> GrayscaleImage {
    GrayscaleImage(width: imageWidth, height: imageHeight, pixels: [Float](repeating: brightness, count: imageWidth * imageHeight))
}

private let markRegion = CGRect(x: 20, y: 16, width: 60, height: 20)

@Suite struct ScreenRegionComparisonTests {
    @Test func theSameScreenIsUnchanged() {
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: textLikeScreen(), region: markRegion))
    }

    @Test func scrollingByALineIsAChange() {
        #expect(ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: textLikeScreen(scrolledUpByRows: 8), region: markRegion))
    }

    @Test func scrollingByAFewPixelsIsAChange() {
        #expect(ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: textLikeScreen(scrolledUpByRows: 3), region: markRegion))
    }

    @Test func aHoverHighlightThatTintsTheBackgroundIsNotAChange() {
        // The background darkens and the text keeps its place, as when hovering a sidebar row.
        let highlighted = transformed(textLikeScreen()) { value, _ in value * 0.7 + 0.05 }
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: highlighted, region: markRegion))
    }

    @Test func invertingTheColorsIsAChange() {
        let inverted = transformed(textLikeScreen()) { value, _ in 1 - value }
        // Inverted colors correlate negatively, which counts as changed. That's right: a
        // theme switch redraws everything, and the marks should go.
        #expect(ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: inverted, region: markRegion))
    }

    @Test func compressionLikeNoiseIsNotAChange() {
        let noisy = transformed(textLikeScreen()) { value, index in
            let noise = Float((index * 7919) % 11) / 11 - 0.5
            return min(max(value + noise * 0.08, 0), 1)
        }
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: noisy, region: markRegion))
    }

    @Test func emptySpaceStaysUnchangedThroughASmallBrightnessShift() {
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: flatScreen(brightness: 0.9), live: flatScreen(brightness: 0.85), region: markRegion))
    }

    @Test func emptySpaceTurningAnotherColorIsAChange() {
        #expect(ScreenRegionComparison.regionHasChanged(baseline: flatScreen(brightness: 0.9), live: flatScreen(brightness: 0.3), region: markRegion))
    }

    @Test func contentAppearingInEmptySpaceIsAChange() {
        #expect(ScreenRegionComparison.regionHasChanged(baseline: flatScreen(brightness: 0.95), live: textLikeScreen(), region: markRegion))
        #expect(ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: flatScreen(brightness: 0.95), region: markRegion))
    }

    @Test func aChangeOnlyWhereThePointerWasIsIgnored() {
        // Something covers all but the right edge of the region, and that part is excluded.
        // Covering only part of a region, like a pointer over a long label, isn't enough to
        // count as a change even without excluding it.
        let coveredOnTheLeft = transformed(textLikeScreen()) { value, index in
            let x = index % imageWidth
            return x < 75 ? 0.5 : value
        }
        let pointerArea = CGRect(x: 0, y: 0, width: 75, height: imageHeight)
        #expect(ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: coveredOnTheLeft, region: markRegion))
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: coveredOnTheLeft, region: markRegion, excludedRegions: [pointerArea]))
    }

    @Test func aChangeOutsideTheRegionIsIgnored() {
        let changedElsewhere = transformed(textLikeScreen()) { value, index in
            index / imageWidth > 60 ? 0.2 : value
        }
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: changedElsewhere, region: markRegion))
    }

    @Test func regionsTooSmallOrOffTheImageCountAsUnchanged() {
        let scrolled = textLikeScreen(scrolledUpByRows: 8)
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: scrolled, region: CGRect(x: 20, y: 16, width: 2, height: 2)))
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: scrolled, region: CGRect(x: 500, y: 500, width: 40, height: 40)))
    }

    @Test func imagesOfDifferentSizesCountAsUnchanged() {
        let smaller = GrayscaleImage(width: 10, height: 10, pixels: [Float](repeating: 0, count: 100))
        #expect(!ScreenRegionComparison.regionHasChanged(baseline: textLikeScreen(), live: smaller, region: markRegion))
    }
}

/// `#expect` can't call a mutating method, so samples are recorded through this.
private func recordSample(_ tracker: inout MarkChangeTracker, markID: Int, changed: Bool) -> Bool {
    tracker.record(markID: markID, regionHasChanged: changed)
}

@Suite struct MarkChangeTrackerTests {
    @Test func aMarkIsStaleOnlyAfterEnoughChangedSamplesInARow() {
        var tracker = MarkChangeTracker(changedSamplesNeeded: 2)
        #expect(!recordSample(&tracker, markID: 1, changed: true))
        #expect(recordSample(&tracker, markID: 1, changed: true))
        // Reported once, not again on every later sample.
        #expect(!recordSample(&tracker, markID: 1, changed: true))
    }

    @Test func anUnchangedSampleStartsTheCountAgain() {
        var tracker = MarkChangeTracker(changedSamplesNeeded: 2)
        #expect(!recordSample(&tracker, markID: 1, changed: true))
        #expect(!recordSample(&tracker, markID: 1, changed: false))
        #expect(!recordSample(&tracker, markID: 1, changed: true))
        #expect(recordSample(&tracker, markID: 1, changed: true))
    }

    @Test func marksAreCountedSeparately() {
        var tracker = MarkChangeTracker(changedSamplesNeeded: 2)
        #expect(!recordSample(&tracker, markID: 1, changed: true))
        #expect(!recordSample(&tracker, markID: 2, changed: true))
        #expect(recordSample(&tracker, markID: 2, changed: true))
        tracker.forget(markID: 1)
        #expect(!recordSample(&tracker, markID: 1, changed: true))
    }
}
