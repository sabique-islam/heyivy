import Foundation

/// The character timings ElevenLabs sends with one piece of streamed audio.
public struct AlignedSpeechChunk: Sendable, Equatable {
    public var characters: [String]
    public var characterStartTimesMilliseconds: [Double]
    public var characterDurationsMilliseconds: [Double]

    public init(characters: [String], characterStartTimesMilliseconds: [Double], characterDurationsMilliseconds: [Double]) {
        self.characters = characters
        self.characterStartTimesMilliseconds = characterStartTimesMilliseconds
        self.characterDurationsMilliseconds = characterDurationsMilliseconds
    }
}

/// A word with the time, in seconds of audio from the start of the stream, when it's spoken.
public struct SpokenWord: Sendable, Equatable {
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var wordIndex: Int

    public init(text: String, startSeconds: Double, endSeconds: Double, wordIndex: Int) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.wordIndex = wordIndex
    }
}

/// What a chunk's character times were counted from.
public enum AlignmentTimeBase: Sendable, Equatable {
    case countedFromStreamStart
    case countedFromChunkStart
}

public enum SpeechTimelineIssue: Sendable, Equatable {
    case timingsWentBackwards(characterIndex: Int)
    case spokenTextDiffersFromSentText
}

/// Turns the character timings of a voice stream into word times on one clock.
///
/// ElevenLabs' docs and our own tests disagree on whether WebSocket timings count from
/// the start of the stream or from the start of each chunk. Rather than trust either,
/// each chunk is compared with how much audio came before it, and the reading that fits
/// is used. Anything that still doesn't add up is recorded in `issues`, so the caller can
/// fall back to marking at sentence starts.
public struct SpeechTimeline: Sendable {
    public private(set) var words: [SpokenWord] = []
    public private(set) var issues: [SpeechTimelineIssue] = []
    public private(set) var chunkTimeBases: [AlignmentTimeBase] = []
    public private(set) var spokenText = ""
    /// One entry per aligned character, as ElevenLabs sent it, with its start time.
    public private(set) var spokenCharacters: [String] = []
    public private(set) var characterStartSeconds: [Double] = []
    public private(set) var hasFinished = false

    /// True once any timing went backwards, so word times can't be trusted.
    public var hasUnreliableTimings: Bool {
        issues.contains { if case .timingsWentBackwards = $0 { return true } else { return false } }
    }

    private var characterCount = 0
    private var previousCharacterStartSeconds: Double?
    private var wordIsInProgress = false

    // Timings are rounded to the millisecond, so a smaller step backwards is just rounding.
    private let backwardsToleranceSeconds = 0.001

    public init() {}

    public mutating func appendChunk(_ chunk: AlignedSpeechChunk, audioSecondsBeforeChunk: Double) {
        guard let firstStartMilliseconds = chunk.characterStartTimesMilliseconds.first else { return }

        // If the first character's time is closer to the audio already played than to
        // zero, the times are already counted from the stream start.
        let firstStartSeconds = firstStartMilliseconds / 1000
        let timeBase: AlignmentTimeBase =
            abs(firstStartSeconds - audioSecondsBeforeChunk) <= abs(firstStartSeconds)
            ? .countedFromStreamStart
            : .countedFromChunkStart
        chunkTimeBases.append(timeBase)
        let offsetSeconds = timeBase == .countedFromChunkStart ? audioSecondsBeforeChunk : 0

        for (characterIndexInChunk, character) in chunk.characters.enumerated() {
            guard characterIndexInChunk < chunk.characterStartTimesMilliseconds.count,
                  characterIndexInChunk < chunk.characterDurationsMilliseconds.count else { break }
            let startMilliseconds = chunk.characterStartTimesMilliseconds[characterIndexInChunk]
            let durationMilliseconds = chunk.characterDurationsMilliseconds[characterIndexInChunk]
            let startSeconds = startMilliseconds / 1000 + offsetSeconds
            let endSeconds = (startMilliseconds + durationMilliseconds) / 1000 + offsetSeconds

            if let previousCharacterStartSeconds, startSeconds < previousCharacterStartSeconds - backwardsToleranceSeconds {
                issues.append(.timingsWentBackwards(characterIndex: characterCount))
            }
            previousCharacterStartSeconds = startSeconds
            characterCount += 1
            spokenText += character
            spokenCharacters.append(character)
            characterStartSeconds.append(startSeconds)

            addCharacterToWords(character, startSeconds: startSeconds, endSeconds: endSeconds)
        }
    }

    /// A word becomes visible when its first character arrives, so a mark can be scheduled
    /// without waiting for the rest of it.
    private mutating func addCharacterToWords(_ character: String, startSeconds: Double, endSeconds: Double) {
        let characterIsWhitespace = character.allSatisfy(\.isWhitespace)
        if characterIsWhitespace {
            wordIsInProgress = false
            return
        }
        if wordIsInProgress, var currentWord = words.popLast() {
            currentWord.text += character
            currentWord.endSeconds = endSeconds
            words.append(currentWord)
        } else {
            words.append(SpokenWord(text: character, startSeconds: startSeconds, endSeconds: endSeconds, wordIndex: words.count))
            wordIsInProgress = true
        }
    }

    public mutating func finishStream() {
        wordIsInProgress = false
        hasFinished = true
    }

    /// Records an issue if the voice spoke different text from what was sent.
    @discardableResult
    public mutating func checkSpokenTextMatches(sentText: String) -> Bool {
        let textMatches =
            spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            == sentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !textMatches { issues.append(.spokenTextDiffersFromSentText) }
        return textMatches
    }
}
