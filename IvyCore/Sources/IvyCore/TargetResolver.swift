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
        // Only full exact matches count here. A line elsewhere holding one of the words, like
        // "Notifications" in a sidebar, doesn't make "Allow notifications" ambiguous.
        let fullExactMatches = candidates.filter { $0.quality == .exact && $0.matchedWordCount == targetWords.count }
        let nearestIsAFullExactMatch = nearestCandidate.quality == .exact && nearestCandidate.matchedWordCount == targetWords.count
        // The one place the whole text appears exactly is trusted wherever it is, and over a
        // nearer partial match, like a "Notifications" heading near a switch whose label is
        // "Allow notifications". Text that appears twice is told apart by position instead.
        if fullExactMatches.count == 1, !nearestIsAFullExactMatch || !isNearRoughPosition, let onlyExactMatch = fullExactMatches.first {
            return .drawOnText(box: onlyExactMatch.box, matchQuality: .exact)
        }
        guard isNearRoughPosition else { return .dropped(.textFarFromRoughPosition) }
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
            let wordByWordCandidate = wordByWordCandidate(targetWords: targetWords, lineWords: lineWords, wordsNeeded: wordsNeeded, roughPosition: roughPosition)
            if let wordByWordCandidate, wordByWordCandidate.matchedWordCount == targetWords.count { return wordByWordCandidate }
            return joinedCandidate(targetWords: targetWords, lineWords: lineWords) ?? wordByWordCandidate
        }
    }

    /// Recognition and Claude don't always split text the same way. Korean "계정 삭제" can
    /// come back as one word, and "(x + 3)" as "(x+3)". So the target's words are joined
    /// without spaces and looked for in the line's words, joined the same way.
    private static func joinedCandidate(targetWords: [String], lineWords: [RecognizedWord]) -> LineCandidate? {
        let joinedTarget = targetWords.joined()
        // Short text would turn up inside longer words, like "cat" in "category".
        guard joinedTarget.count >= 4 else { return nil }
        let orderedWords = lineWords.sorted { $0.boxInImagePixels.minX < $1.boxInImagePixels.minX }
        var joinedLine = ""
        var wordRanges: [(range: Range<Int>, box: CGRect)] = []
        for lineWord in orderedWords {
            let normalizedWord = normalizedForMatching(lineWord.text)
            wordRanges.append((joinedLine.count..<(joinedLine.count + normalizedWord.count), lineWord.boxInImagePixels))
            joinedLine += normalizedWord
        }
        guard let foundRange = joinedLine.range(of: joinedTarget) else { return nil }
        let foundStart = joinedLine.distance(from: joinedLine.startIndex, to: foundRange.lowerBound)
        let foundCharacters = foundStart..<(foundStart + joinedTarget.count)
        let coveredWords = wordRanges.filter { $0.range.overlaps(foundCharacters) }
        guard let firstBox = coveredWords.first?.box else { return nil }
        // The match must make up most of the words it falls in, not be a small piece of one.
        let coveredCharacterCount = coveredWords.map(\.range.count).reduce(0, +)
        guard joinedTarget.count * 10 >= coveredCharacterCount * 6 else { return nil }
        let mergedBox = coveredWords.dropFirst().reduce(firstBox) { $0.union($1.box) }
        return LineCandidate(box: mergedBox, matchedWordCount: targetWords.count, quality: .exact)
    }

    private static func wordByWordCandidate(targetWords: [String], lineWords: [RecognizedWord], wordsNeeded: Int, roughPosition: CGPoint) -> LineCandidate? {
        var matchedBoxes: [CGRect] = []
        var everyWordMatchedExactly = true
        for targetWord in targetWords {
            // If a word appears twice on the line, the occurrence nearest the position wins.
            let matches = lineWords.compactMap { recognizedWord -> (box: CGRect, isExact: Bool)? in
                let recognizedText = normalizedForMatching(recognizedWord.text)
                if recognizedText == targetWord { return (recognizedWord.boxInImagePixels, true) }
                if let partBox = boxOfCodeTokenInsideWord(targetWord: targetWord, recognizedText: recognizedText, recognizedBox: recognizedWord.boxInImagePixels) {
                    return (partBox, false)
                }
                if isCloseMatch(recognizedText, targetWord) { return (recognizedWord.boxInImagePixels, false) }
                return nil
            }
            guard let bestMatch = matches.min(by: {
                ($0.isExact ? 0 : 1, distance(from: roughPosition, to: $0.box))
                    < ($1.isExact ? 0 : 1, distance(from: roughPosition, to: $1.box))
            }) else {
                everyWordMatchedExactly = false
                continue
            }
            if !bestMatch.isExact { everyWordMatchedExactly = false }
            matchedBoxes.append(bestMatch.box)
        }
        guard matchedBoxes.count >= wordsNeeded, let firstBox = matchedBoxes.first else { return nil }
        let mergedBox = matchedBoxes.dropFirst().reduce(firstBox) { $0.union($1) }
        return LineCandidate(box: mergedBox, matchedWordCount: matchedBoxes.count, quality: everyWordMatchedExactly ? .exact : .close)
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

    /// Recognition often reads a line of code as one long word, like fmt.Println(values[i]).
    /// A target with code punctuation, like values[i], is then found inside it, and the box is
    /// narrowed to its share of the characters. Plain words aren't, so "cat" never matches
    /// inside "category". Seen in the D6 eval, where values[i] otherwise went to a lone
    /// "values" on the line above.
    static func boxOfCodeTokenInsideWord(targetWord: String, recognizedText: String, recognizedBox: CGRect) -> CGRect? {
        let looksLikeCode = targetWord.contains { "()[]{}.<>=:;_/\\\"'".contains($0) }
        guard looksLikeCode, targetWord.count >= 4, recognizedText.count > targetWord.count,
              let foundRange = recognizedText.range(of: targetWord) else { return nil }
        let characterWidth = recognizedBox.width / Double(recognizedText.count)
        let startOffset = Double(recognizedText.distance(from: recognizedText.startIndex, to: foundRange.lowerBound))
        return CGRect(x: recognizedBox.minX + startOffset * characterWidth, y: recognizedBox.minY, width: Double(targetWord.count) * characterWidth, height: recognizedBox.height)
    }

    /// Tolerates a plural, a cut-off word, one wrong letter in a longer word, and misread
    /// punctuation in a long token of code.
    static func isCloseMatch(_ recognizedText: String, _ targetWord: String) -> Bool {
        guard recognizedText.count >= 3, targetWord.count >= 3 else { return false }
        // One inside the other counts only when the shorter is most of the longer. Otherwise
        // a lone "response" would match response.json["name"].
        let shorterCount = min(recognizedText.count, targetWord.count)
        let longerCount = max(recognizedText.count, targetWord.count)
        if (recognizedText.contains(targetWord) || targetWord.contains(recognizedText)) && shorterCount * 10 >= longerCount * 6 { return true }
        if targetWord.count >= 5 && editDistance(recognizedText, targetWord) <= 1 { return true }
        // Recognition misreads quotes and brackets in code, like response.json["name"] read
        // as response.json[inamel]. Long tokens are compared by letters and digits alone,
        // allowing one slip in every six characters.
        let recognizedLettersAndDigits = recognizedText.filter { $0.isLetter || $0.isNumber }
        let targetLettersAndDigits = targetWord.filter { $0.isLetter || $0.isNumber }
        guard targetLettersAndDigits.count >= 10 else { return false }
        return editDistance(recognizedLettersAndDigits, targetLettersAndDigits) <= targetLettersAndDigits.count / 6
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
