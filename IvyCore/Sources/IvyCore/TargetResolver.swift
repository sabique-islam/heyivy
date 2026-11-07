import CoreGraphics
import Foundation

/// A word found on screen by text recognition, in screenshot pixels with the origin at the top left.
public struct RecognizedWord: Sendable, Equatable {
    public var text: String
    public var boxInImagePixels: CGRect
    /// Words on the same line share an index, so a target is never merged across lines.
    public var lineIndex: Int

    public init(text: String, boxInImagePixels: CGRect, lineIndex: Int) {
        self.text = text
        self.boxInImagePixels = boxInImagePixels
        self.lineIndex = lineIndex
    }
}

public enum TextMatchQuality: Sendable, Equatable {
    /// Every named word matched exactly, ignoring case and punctuation.
    case exact
    /// Enough words matched, some only partly. Drawn, and worth logging.
    case close
}

public enum TargetDropReason: Sendable, Equatable {
    /// The text was found, but far from where Claude said it was, and either it appears
    /// more than once or it only partly matched, so there's no telling which place was meant.
    case textFarFromRoughPosition
    case textNotFound
    case positionOffScreen
    case textRecognitionNotReady
}

public enum TargetResolution: Sendable, Equatable {
    case drawOnText(box: CGRect, matchQuality: TextMatchQuality)
    /// For marks without text: a wider area around Claude's position.
    case drawAroundPosition(box: CGRect)
    case dropped(TargetDropReason)
}

public struct TargetResolverSettings: Sendable {
    /// How far a match may be from Claude's rough position, as a share of the screenshot's longer side.
    public var nearDistanceFraction = 0.08
    /// Half the size of the area drawn around a mark that has no text.
    public var nonTextRadiusPixels = 60.0

    public init() {}
}

/// Finds where a mark should go, using text recognition to correct Claude's rough position.
///
/// A missing mark is better than a wrong one: the explanation still works without it, and
/// a wrong circle breaks trust. Claude reads text far more reliably than it places points,
/// though, so text that matches exactly and appears only once on screen is trusted wherever
/// it is. When the text and the position disagree otherwise, the mark is dropped.
public enum TargetResolver {
    public static func resolve(
        mark: MarkRequest,
        recognizedWords: [RecognizedWord]?,
        imagePixelSize: CGSize,
        settings: TargetResolverSettings = TargetResolverSettings()
    ) -> TargetResolution {
        let roughPosition = CGPoint(x: mark.roughPositionInImagePixels.x, y: mark.roughPositionInImagePixels.y)
        let imageBounds = CGRect(origin: .zero, size: imagePixelSize)
        guard imageBounds.contains(roughPosition) else { return .dropped(.positionOffScreen) }

        let targetWords: [String]
        switch mark.target {
        case .nonText, .labelText:
            let areaAroundPosition = CGRect(
                x: roughPosition.x - settings.nonTextRadiusPixels,
                y: roughPosition.y - settings.nonTextRadiusPixels,
                width: settings.nonTextRadiusPixels * 2,
                height: settings.nonTextRadiusPixels * 2
            ).intersection(imageBounds)
            return .drawAroundPosition(box: areaAroundPosition)
        case .visibleText(let words):
            targetWords = words.map(normalizedForMatching).filter { !$0.isEmpty }
        }

        guard let recognizedWords else { return .dropped(.textRecognitionNotReady) }
        guard !targetWords.isEmpty else { return .dropped(.textNotFound) }

        let candidates = lineCandidates(targetWords: targetWords, recognizedWords: recognizedWords, roughPosition: roughPosition)
        // Repeated text, like two calls to the same function, is told apart by position.
        guard let nearestCandidate = candidates.min(by: { first, second in
            let firstDistance = distance(from: roughPosition, to: first.box)
            let secondDistance = distance(from: roughPosition, to: second.box)
            return firstDistance == secondDistance ? first.matchedWordCount > second.matchedWordCount : firstDistance < secondDistance
        }) else {
            return .dropped(.textNotFound)
        }

        let nearDistance = settings.nearDistanceFraction * max(imagePixelSize.width, imagePixelSize.height)
        let isNearRoughPosition = distance(from: roughPosition, to: nearestCandidate.box) <= nearDistance
        // An exact match means every named word was found, each one exactly.
        let isTheOnlyExactMatchOnScreen = candidates.count == 1 && nearestCandidate.quality == .exact
        guard isNearRoughPosition || isTheOnlyExactMatchOnScreen else {
            return .dropped(.textFarFromRoughPosition)
        }
        return .drawOnText(box: nearestCandidate.box, matchQuality: nearestCandidate.quality)
    }

    private struct LineCandidate {
        var box: CGRect
        var matchedWordCount: Int
        var quality: TextMatchQuality
    }

    /// One candidate per line holding at least half of the named words.
    private static func lineCandidates(targetWords: [String], recognizedWords: [RecognizedWord], roughPosition: CGPoint) -> [LineCandidate] {
        let wordsByLine = Dictionary(grouping: recognizedWords, by: \.lineIndex)
        let wordsNeeded = (targetWords.count + 1) / 2

        return wordsByLine.values.compactMap { lineWords in
            var matchedBoxes: [CGRect] = []
            var everyWordMatchedExactly = true
            for targetWord in targetWords {
                // If a word appears twice on the line, the occurrence nearest the position wins.
                let matches = lineWords.compactMap { recognizedWord -> (word: RecognizedWord, isExact: Bool)? in
                    let recognizedText = normalizedForMatching(recognizedWord.text)
                    if recognizedText == targetWord { return (recognizedWord, true) }
                    if isCloseMatch(recognizedText, targetWord) { return (recognizedWord, false) }
                    return nil
                }
                guard let bestMatch = matches.min(by: {
                    ($0.isExact ? 0 : 1, distance(from: roughPosition, to: $0.word.boxInImagePixels))
                        < ($1.isExact ? 0 : 1, distance(from: roughPosition, to: $1.word.boxInImagePixels))
                }) else {
                    everyWordMatchedExactly = false
                    continue
                }
                if !bestMatch.isExact { everyWordMatchedExactly = false }
                matchedBoxes.append(bestMatch.word.boxInImagePixels)
            }
            guard matchedBoxes.count >= wordsNeeded, let firstBox = matchedBoxes.first else { return nil }
            let mergedBox = matchedBoxes.dropFirst().reduce(firstBox) { $0.union($1) }
            return LineCandidate(box: mergedBox, matchedWordCount: matchedBoxes.count, quality: everyWordMatchedExactly ? .exact : .close)
        }
    }

    /// Lowercased, with typographic dashes and quotes made plain and edge punctuation removed.
    /// "fibonacci(n" and "fibonacci(n)" both become "fibonacci(n".
    public static func normalizedForMatching(_ text: String) -> String {
        var normalizedText = text.lowercased()
        for dash in ["\u{2212}", "\u{2013}", "\u{2014}", "\u{2012}"] {
            normalizedText = normalizedText.replacingOccurrences(of: dash, with: "-")
        }
        for (curly, plain) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            normalizedText = normalizedText.replacingOccurrences(of: curly, with: plain)
        }
        let edgePunctuation = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "(["))
        let trimmedText = normalizedText.trimmingCharacters(in: edgePunctuation.union(.whitespaces))
        // A word that's all punctuation, like "-", is kept as it is.
        return trimmedText.isEmpty ? normalizedText.trimmingCharacters(in: .whitespaces) : trimmedText
    }

    /// Tolerates a plural, a cut-off word, or one wrong letter in a longer word.
    private static func isCloseMatch(_ recognizedText: String, _ targetWord: String) -> Bool {
        guard recognizedText.count >= 3, targetWord.count >= 3 else { return false }
        if recognizedText.contains(targetWord) || targetWord.contains(recognizedText) { return true }
        return targetWord.count >= 5 && editDistance(recognizedText, targetWord) <= 1
    }

    private static func editDistance(_ first: String, _ second: String) -> Int {
        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        var previousRow = Array(0...secondCharacters.count)
        for (firstIndex, firstCharacter) in firstCharacters.enumerated() {
            var currentRow = [firstIndex + 1]
            for (secondIndex, secondCharacter) in secondCharacters.enumerated() {
                let substitutionCost = firstCharacter == secondCharacter ? 0 : 1
                currentRow.append(min(previousRow[secondIndex + 1] + 1, currentRow[secondIndex] + 1, previousRow[secondIndex] + substitutionCost))
            }
            previousRow = currentRow
        }
        return previousRow[secondCharacters.count]
    }

    /// Zero inside the box, otherwise the distance to its nearest edge.
    private static func distance(from point: CGPoint, to box: CGRect) -> Double {
        let horizontalGap = max(box.minX - point.x, 0, point.x - box.maxX)
        let verticalGap = max(box.minY - point.y, 0, point.y - box.maxY)
        return (horizontalGap * horizontalGap + verticalGap * verticalGap).squareRoot()
    }
}

/// Where one screenshot came from, so its pixels can be turned into screen points.
///
/// The conversion is image pixels to display points, then flipping Y because AppKit counts
/// from the bottom, then adding the display's position. Each capture carries its own size
/// and frame, so displays with different resolutions each convert correctly.
public struct CapturedScreenGeometry: Sendable, Equatable {
    public var imagePixelSize: CGSize
    /// The display's frame in AppKit's global coordinates, with the origin at the bottom left
    /// of the main display, as `NSScreen.frame` gives it.
    public var screenFrameInGlobalPoints: CGRect

    public init(imagePixelSize: CGSize, screenFrameInGlobalPoints: CGRect) {
        self.imagePixelSize = imagePixelSize
        self.screenFrameInGlobalPoints = screenFrameInGlobalPoints
    }

    private var pointsPerPixelHorizontally: Double { screenFrameInGlobalPoints.width / imagePixelSize.width }
    private var pointsPerPixelVertically: Double { screenFrameInGlobalPoints.height / imagePixelSize.height }

    public func globalRect(fromImagePixelRect pixelRect: CGRect) -> CGRect {
        CGRect(
            x: screenFrameInGlobalPoints.minX + pixelRect.minX * pointsPerPixelHorizontally,
            y: screenFrameInGlobalPoints.maxY - pixelRect.maxY * pointsPerPixelVertically,
            width: pixelRect.width * pointsPerPixelHorizontally,
            height: pixelRect.height * pointsPerPixelVertically
        )
    }

    public func imagePixelRect(fromGlobalRect globalRect: CGRect) -> CGRect {
        CGRect(
            x: (globalRect.minX - screenFrameInGlobalPoints.minX) / pointsPerPixelHorizontally,
            y: (screenFrameInGlobalPoints.maxY - globalRect.maxY) / pointsPerPixelVertically,
            width: globalRect.width / pointsPerPixelHorizontally,
            height: globalRect.height / pointsPerPixelVertically
        )
    }
}
