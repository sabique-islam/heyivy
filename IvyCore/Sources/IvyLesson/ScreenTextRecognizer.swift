import CoreGraphics
import Foundation
import IvyCore
import Vision

/// Finds the words on a screenshot with Apple's on-device text recognition, so marks can
/// snap to the exact text Claude named. Nothing leaves the Mac.
public enum ScreenTextRecognizer {
    /// The first recognition in a new build took about 52 seconds in testing, and later ones
    /// about a quarter of a second. Calling this at launch takes that hit before any lesson.
    public static func warmUpInBackground() {
        Task.detached(priority: .utility) { warmUp() }
    }

    /// Runs one tiny recognition and returns how long it took, in seconds.
    @discardableResult
    public static func warmUp() -> Double {
        let startSeconds = ProcessInfo.processInfo.systemUptime
        let warmUpContext = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        if let warmUpImage = warmUpContext?.makeImage() {
            _ = try? recognizeWords(in: warmUpImage, reportedInPixelSize: CGSize(width: 64, height: 32))
        }
        return ProcessInfo.processInfo.systemUptime - startSeconds
    }

    /// Recognizes text on `image`, and reports each word's box in a screenshot of
    /// `reportedInPixelSize`, top-left origin. That lets recognition run on the full-resolution
    /// capture while boxes line up with the smaller image Claude saw.
    public static func recognizeWords(in image: CGImage, reportedInPixelSize: CGSize) throws -> [RecognizedWord] {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        // Code and names aren't dictionary words, so correction would change them.
        textRequest.usesLanguageCorrection = false
        // English-only recognition reads Japanese, Korean and Arabic as nonsense. Detecting the
        // language fixed all three on the evaluation screens, at no measurable cost in time.
        textRequest.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([textRequest])

        var recognizedWords: [RecognizedWord] = []
        for (lineIndex, lineObservation) in (textRequest.results ?? []).enumerated() {
            guard let bestCandidate = lineObservation.topCandidates(1).first else { continue }
            let lineText = bestCandidate.string
            var searchStart = lineText.startIndex
            for word in lineText.split(whereSeparator: \.isWhitespace) {
                guard let wordRange = lineText.range(of: word, range: searchStart..<lineText.endIndex) else { continue }
                searchStart = wordRange.upperBound
                guard let normalizedBox = try? bestCandidate.boundingBox(for: wordRange)?.boundingBox else { continue }
                // Vision's boxes are 0 to 1 with the origin at the bottom left.
                let wordBox = CGRect(
                    x: normalizedBox.minX * reportedInPixelSize.width,
                    y: (1 - normalizedBox.maxY) * reportedInPixelSize.height,
                    width: normalizedBox.width * reportedInPixelSize.width,
                    height: normalizedBox.height * reportedInPixelSize.height
                )
                recognizedWords.append(RecognizedWord(text: String(word), boxInImagePixels: wordBox, lineIndex: lineIndex))
            }
        }
        return recognizedWords
    }
}
