import CoreGraphics
import Testing
@testable import IvyCore

private let screenImageSize = CGSize(width: 2000, height: 1200)

private func word(_ text: String, x: Double, y: Double, width: Double = 60, line: Int) -> RecognizedWord {
    RecognizedWord(text: text, boxInImagePixels: CGRect(x: x, y: y, width: width, height: 20), lineIndex: line)
}

private func textMark(_ words: [String], near point: PixelPoint, kind: MarkKind = .circle) -> MarkRequest {
    MarkRequest(markIndex: 0, kind: kind, target: .visibleText(words: words), roughPositionInImagePixels: point, spokenWords: "it", spokenCharacterOffset: 0)
}

@Suite struct TargetResolverTests {
    private let screenWords = [
        word("let", x: 100, y: 100, line: 0),
        word("total", x: 170, y: 100, line: 0),
        word("=", x: 240, y: 100, width: 10, line: 0),
        word("fibonacci(n)", x: 260, y: 100, width: 120, line: 0),
        word("return", x: 100, y: 600, line: 1),
        word("fibonacci(n)", x: 170, y: 600, width: 120, line: 1),
        word("Export", x: 1500, y: 40, line: 2),
        word("as", x: 1570, y: 40, width: 20, line: 2),
        word("PDF", x: 1600, y: 40, width: 40, line: 2),
        word("x", x: 900, y: 900, width: 10, line: 3),
        word("−", x: 915, y: 900, width: 10, line: 3),
        word("1", x: 930, y: 900, width: 10, line: 3),
    ]

    @Test func anExactMatchNearTheRoughPositionDrawsOnTheExactBox() {
        let resolution = TargetResolver.resolve(mark: textMark(["Export", "as", "PDF"], near: PixelPoint(x: 1560, y: 45)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(resolution == .drawOnText(box: CGRect(x: 1500, y: 40, width: 140, height: 20), matchQuality: .exact))
    }

    @Test func repeatedTextIsResolvedByTheRoughPosition() {
        let nearTop = TargetResolver.resolve(mark: textMark(["fibonacci(n"], near: PixelPoint(x: 300, y: 110)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        let nearBottom = TargetResolver.resolve(mark: textMark(["fibonacci(n"], near: PixelPoint(x: 220, y: 590)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(nearTop == .drawOnText(box: CGRect(x: 260, y: 100, width: 120, height: 20), matchQuality: .exact))
        #expect(nearBottom == .drawOnText(box: CGRect(x: 170, y: 600, width: 120, height: 20), matchQuality: .exact))
    }

    @Test func caseAndPunctuationAndUnicodeMinusAreTolerated() {
        let resolution = TargetResolver.resolve(mark: textMark(["EXPORT", "pdf."], near: PixelPoint(x: 1560, y: 45)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(resolution == .drawOnText(box: CGRect(x: 1500, y: 40, width: 140, height: 20), matchQuality: .exact))
        let minusResolution = TargetResolver.resolve(mark: textMark(["x", "-", "1"], near: PixelPoint(x: 920, y: 905)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(minusResolution == .drawOnText(box: CGRect(x: 900, y: 900, width: 40, height: 20), matchQuality: .exact))
    }

    @Test func aPartialMatchStillDrawsButIsMarkedClose() {
        let resolution = TargetResolver.resolve(mark: textMark(["Exports", "as", "PDFs"], near: PixelPoint(x: 1560, y: 45)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(resolution == .drawOnText(box: CGRect(x: 1500, y: 40, width: 140, height: 20), matchQuality: .close))
    }

    @Test func atLeastHalfTheNamedWordsMustBeFound() {
        let resolution = TargetResolver.resolve(mark: textMark(["Export", "to", "Word"], near: PixelPoint(x: 1560, y: 45)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(resolution == .dropped(.textNotFound))
    }

    @Test func matchingTextFarFromTheRoughPositionIsDropped() {
        let resolution = TargetResolver.resolve(mark: textMark(["Export", "as", "PDF"], near: PixelPoint(x: 200, y: 1000)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(resolution == .dropped(.textFarFromRoughPosition))
    }

    @Test func textThatIsNotOnScreenIsDropped() {
        let resolution = TargetResolver.resolve(mark: textMark(["Settings"], near: PixelPoint(x: 100, y: 100)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(resolution == .dropped(.textNotFound))
    }

    @Test func aNonTextTargetDrawsAWiderCircleAroundThePosition() {
        let mark = MarkRequest(markIndex: 0, kind: .circle, target: .nonText, roughPositionInImagePixels: PixelPoint(x: 500, y: 400), spokenWords: "it", spokenCharacterOffset: 0)
        let resolution = TargetResolver.resolve(mark: mark, recognizedWords: nil, imagePixelSize: screenImageSize)
        #expect(resolution == .drawAroundPosition(box: CGRect(x: 440, y: 340, width: 120, height: 120)))
    }

    @Test func aLabelIsPlacedAtItsPositionWithoutLookingForText() {
        let mark = MarkRequest(markIndex: 0, kind: .label, target: .labelText("Save"), roughPositionInImagePixels: PixelPoint(x: 10, y: 10), spokenWords: "it", spokenCharacterOffset: 0)
        let resolution = TargetResolver.resolve(mark: mark, recognizedWords: nil, imagePixelSize: screenImageSize)
        #expect(resolution == .drawAroundPosition(box: CGRect(x: 0, y: 0, width: 70, height: 70)))
    }

    @Test func aTextMarkIsDroppedWhenTextRecognitionIsNotReady() {
        let resolution = TargetResolver.resolve(mark: textMark(["Export"], near: PixelPoint(x: 1500, y: 40)), recognizedWords: nil, imagePixelSize: screenImageSize)
        #expect(resolution == .dropped(.textRecognitionNotReady))
    }

    @Test func aPositionOffTheScreenIsDropped() {
        let resolution = TargetResolver.resolve(mark: textMark(["Export"], near: PixelPoint(x: 2500, y: 40)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        #expect(resolution == .dropped(.positionOffScreen))
        let nonText = MarkRequest(markIndex: 0, kind: .circle, target: .nonText, roughPositionInImagePixels: PixelPoint(x: -5, y: 40), spokenWords: "it", spokenCharacterOffset: 0)
        #expect(TargetResolver.resolve(mark: nonText, recognizedWords: nil, imagePixelSize: screenImageSize) == .dropped(.positionOffScreen))
    }

    @Test func wordsOnDifferentLinesAreNotMergedIntoOneBox() {
        let resolution = TargetResolver.resolve(mark: textMark(["let", "return"], near: PixelPoint(x: 120, y: 110)), recognizedWords: screenWords, imagePixelSize: screenImageSize)
        // Only one of the two words is on any one line, which is half, so it draws on that line alone.
        #expect(resolution == .drawOnText(box: CGRect(x: 100, y: 100, width: 60, height: 20), matchQuality: .close))
    }
}

@Suite struct ScreenCoordinateTests {
    @Test func aRetinaPrimaryDisplayHalvesPixelsAndFlipsY() {
        let geometry = CapturedScreenGeometry(imagePixelSize: CGSize(width: 2880, height: 1800), screenFrameInGlobalPoints: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let rect = geometry.globalRect(fromImagePixelRect: CGRect(x: 100, y: 200, width: 40, height: 20))
        #expect(rect == CGRect(x: 50, y: 790, width: 20, height: 10))
    }

    @Test func aDownscaledCaptureScalesBackToPoints() {
        // Captures are shrunk before sending, so 1280 pixels can cover 1512 points.
        let geometry = CapturedScreenGeometry(imagePixelSize: CGSize(width: 1280, height: 827), screenFrameInGlobalPoints: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let rect = geometry.globalRect(fromImagePixelRect: CGRect(x: 640, y: 0, width: 128, height: 0))
        #expect(abs(rect.minX - 756) < 0.001)
        #expect(abs(rect.width - 151.2) < 0.001)
        #expect(abs(rect.maxY - 982) < 0.001)
    }

    @Test func aDisplayToTheLeftHasANegativeOrigin() {
        let geometry = CapturedScreenGeometry(imagePixelSize: CGSize(width: 1920, height: 1080), screenFrameInGlobalPoints: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let rect = geometry.globalRect(fromImagePixelRect: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(rect == CGRect(x: -1920, y: 1070, width: 10, height: 10))
    }

    @Test func aDisplayAboveThePrimaryHasAHigherY() {
        let geometry = CapturedScreenGeometry(imagePixelSize: CGSize(width: 1920, height: 1080), screenFrameInGlobalPoints: CGRect(x: 200, y: 900, width: 1920, height: 1080))
        let rect = geometry.globalRect(fromImagePixelRect: CGRect(x: 0, y: 1070, width: 10, height: 10))
        #expect(rect == CGRect(x: 200, y: 900, width: 10, height: 10))
    }

    @Test func mixedResolutionDisplaysEachUseTheirOwnScale() {
        let retina = CapturedScreenGeometry(imagePixelSize: CGSize(width: 2880, height: 1800), screenFrameInGlobalPoints: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let standard = CapturedScreenGeometry(imagePixelSize: CGSize(width: 1920, height: 1080), screenFrameInGlobalPoints: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let samePixels = CGRect(x: 100, y: 100, width: 100, height: 100)
        #expect(retina.globalRect(fromImagePixelRect: samePixels).width == 50)
        #expect(standard.globalRect(fromImagePixelRect: samePixels).width == 100)
        #expect(standard.globalRect(fromImagePixelRect: samePixels).minX == 1540)
    }

    @Test func aPointRoundTripsThroughBothConversions() {
        let geometry = CapturedScreenGeometry(imagePixelSize: CGSize(width: 2880, height: 1800), screenFrameInGlobalPoints: CGRect(x: -1440, y: 300, width: 1440, height: 900))
        let original = CGRect(x: 333, y: 777, width: 44, height: 22)
        let roundTripped = geometry.imagePixelRect(fromGlobalRect: geometry.globalRect(fromImagePixelRect: original))
        #expect(abs(roundTripped.minX - original.minX) < 1e-9 && abs(roundTripped.minY - original.minY) < 1e-9)
    }
}
