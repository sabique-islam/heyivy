import Foundation

/// The marks Claude can ask for. Anything else is spoken but not drawn.
public enum MarkKind: String, CaseIterable, Sendable {
    case circle
    case underline
    case highlight
    case arrow
    case label
}

public enum MarkTarget: Sendable, Equatable {
    /// Up to 3 words that are visible on screen, to be found by text recognition.
    case visibleText(words: [String])
    /// An icon, chart bar, or anything else without text, drawn at the rough position.
    case nonText
    /// The short text a `label` mark shows at its position.
    case labelText(String)
}

/// A position in the screenshot Claude saw, in its pixels, with the origin at the top left.
public struct PixelPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A mark Claude asked for, tied to the words it belongs to in the spoken text.
public struct MarkRequest: Sendable, Equatable {
    public var markIndex: Int
    public var kind: MarkKind
    public var target: MarkTarget
    public var roughPositionInImagePixels: PixelPoint
    /// The wrapped words, which are spoken as normal.
    public var spokenWords: String
    /// Where those words begin in the speech, counted in characters, so the mark can fire
    /// as they're said.
    public var spokenCharacterOffset: Int

    public init(markIndex: Int, kind: MarkKind, target: MarkTarget, roughPositionInImagePixels: PixelPoint, spokenWords: String, spokenCharacterOffset: Int) {
        self.markIndex = markIndex
        self.kind = kind
        self.target = target
        self.roughPositionInImagePixels = roughPositionInImagePixels
        self.spokenWords = spokenWords
        self.spokenCharacterOffset = spokenCharacterOffset
    }
}

public enum ScriptParserOutput: Sendable, Equatable {
    /// Text to send to the voice. It never contains wrapper syntax or Markdown.
    case speech(String)
    /// A mark, emitted just before the speech that carries its words.
    case mark(MarkRequest)
}

/// Why a mark was dropped while its words were still spoken.
public enum DroppedMarkReason: Sendable, Equatable {
    case malformed
    case unknownKind
    case invalidPosition
    case tooManyMarks
}

/// Limits are enforced here, because in testing the model broke its mark limit.
public struct LessonScriptLimits: Sendable {
    public var maximumMarksPerReply = 5
    public var maximumTargetWords = 3
    public var maximumLabelCharacters = 24
    /// How long an unclosed `{{` holds speech back before it's treated as broken.
    public var maximumHeldWrapperCharacters = 200

    public init() {}
}

/// Reads Claude's script as it streams in and splits it into speech and marks.
///
/// A mark wraps the words it belongs to: `{{spoken words|kind|visible text or -|x,y}}`.
/// Wrappers were split across stream chunks in every test reply, so this works one
/// character at a time and gives the same result however the text is split. Speech is
/// released as soon as it can't be part of a wrapper, so the voice isn't kept waiting.
public struct LessonScriptParser: Sendable {
    public let limits: LessonScriptLimits
    public private(set) var droppedMarks: [DroppedMarkReason] = []

    private var markdownStripper = SpeechMarkdownStripper()
    private var unprocessedText = ""
    private var isInsideWrapper = false
    private var spokenCharacterCount = 0
    private var acceptedMarkCount = 0
    // Built up during one call to consume or finish, then handed back.
    private var outputsInProgress: [ScriptParserOutput] = []
    private var speechNotYetOutput = ""
    private var lastSpokenCharacter: Character?

    private static let wrapperOpening = "{{"
    private static let wrapperClosing = "}}"

    public init(limits: LessonScriptLimits = LessonScriptLimits()) {
        self.limits = limits
    }

    public mutating func consume(_ streamedText: String) -> [ScriptParserOutput] {
        unprocessedText += streamedText
        return processUnprocessedText(isEndOfReply: false)
    }

    /// Call once the reply is complete, to release anything still held back.
    public mutating func finish() -> [ScriptParserOutput] {
        processUnprocessedText(isEndOfReply: true)
    }

    /// The one place speech leaves the parser. Removing Markdown can bring two separate
    /// braces together, as in "{`{", so a brace that would make "{{" is dropped here,
    /// whatever produced it. Wrapper syntax can then never reach the voice.
    private mutating func addSpeech(_ spokenText: String) {
        for character in spokenText {
            if character == "{" && lastSpokenCharacter == "{" { continue }
            speechNotYetOutput.append(character)
            spokenCharacterCount += 1
            lastSpokenCharacter = character
        }
    }

    /// Speech before a mark goes out first, so the mark's offset matches what's been spoken.
    private mutating func outputPendingSpeech() {
        if !speechNotYetOutput.isEmpty { outputsInProgress.append(.speech(speechNotYetOutput)) }
        speechNotYetOutput = ""
    }

    private mutating func processUnprocessedText(isEndOfReply: Bool) -> [ScriptParserOutput] {
        outputsInProgress = []

        while true {
            if !isInsideWrapper {
                if let openingRange = unprocessedText.range(of: Self.wrapperOpening) {
                    let textBeforeWrapper = String(unprocessedText[..<openingRange.lowerBound])
                    addSpeech(markdownStripper.consume(textBeforeWrapper))
                    addSpeech(markdownStripper.flush(nextCharacter: "{"))
                    unprocessedText = String(unprocessedText[openingRange.upperBound...])
                    isInsideWrapper = true
                    continue
                }
                // A lone trailing "{" might be the first half of "{{", so it waits for the next text.
                let textToSpeak: String
                if !isEndOfReply && unprocessedText.hasSuffix("{") {
                    textToSpeak = String(unprocessedText.dropLast())
                    unprocessedText = "{"
                } else {
                    textToSpeak = unprocessedText
                    unprocessedText = ""
                }
                addSpeech(markdownStripper.consume(textToSpeak))
                if isEndOfReply { addSpeech(markdownStripper.flush(nextCharacter: nil)) }
                break
            }

            // Inside a wrapper: wait for "}}", but only for so long.
            let heldLimit = limits.maximumHeldWrapperCharacters
            if let closingRange = unprocessedText.range(of: Self.wrapperClosing),
               unprocessedText.distance(from: unprocessedText.startIndex, to: closingRange.lowerBound) <= heldLimit {
                let wrapperContent = String(unprocessedText[..<closingRange.lowerBound])
                unprocessedText = String(unprocessedText[closingRange.upperBound...])
                isInsideWrapper = false
                outputPendingSpeech()
                handleWrapper(wrapperContent, wasClosed: true)
                continue
            }
            // Two characters past the limit settles whether "}}" could still close within it.
            if unprocessedText.count >= heldLimit + 2 {
                let heldContent = String(unprocessedText.prefix(heldLimit))
                unprocessedText = String(unprocessedText.dropFirst(heldLimit))
                isInsideWrapper = false
                outputPendingSpeech()
                handleWrapper(heldContent, wasClosed: false)
                continue
            }
            if isEndOfReply {
                let heldContent = unprocessedText
                unprocessedText = ""
                isInsideWrapper = false
                outputPendingSpeech()
                handleWrapper(heldContent, wasClosed: false)
                continue
            }
            break
        }

        outputPendingSpeech()
        defer { outputsInProgress = [] }
        return outputsInProgress
    }

    private mutating func handleWrapper(_ wrapperContent: String, wasClosed: Bool) {
        let fields = wrapperContent.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let spokenWords = Self.speakableWords(from: fields.first ?? "")
        let trimmedSpokenWords = spokenWords.trimmingCharacters(in: .whitespacesAndNewlines)

        guard wasClosed, fields.count >= 4, !trimmedSpokenWords.isEmpty else {
            speakWordsWithoutMark(spokenWords, because: .malformed)
            return
        }
        guard let kind = MarkKind(rawValue: fields[1].trimmingCharacters(in: .whitespaces).lowercased()) else {
            speakWordsWithoutMark(spokenWords, because: .unknownKind)
            return
        }
        guard let roughPosition = Self.parsePosition(fields[fields.count - 1]) else {
            speakWordsWithoutMark(spokenWords, because: .invalidPosition)
            return
        }
        // The visible text may itself contain "|", so everything between kind and position is the target.
        let targetText = fields[2..<(fields.count - 1)].joined(separator: "|").trimmingCharacters(in: .whitespaces)
        guard !targetText.isEmpty else {
            speakWordsWithoutMark(spokenWords, because: .malformed)
            return
        }
        guard acceptedMarkCount < limits.maximumMarksPerReply else {
            speakWordsWithoutMark(spokenWords, because: .tooManyMarks)
            return
        }

        let target: MarkTarget
        if kind == .label {
            target = .labelText(String(targetText.prefix(limits.maximumLabelCharacters)).trimmingCharacters(in: .whitespaces))
        } else if targetText == "-" {
            target = .nonText
        } else {
            target = .visibleText(words: Array(targetText.split(whereSeparator: \.isWhitespace).prefix(limits.maximumTargetWords).map(String.init)))
        }

        outputsInProgress.append(.mark(MarkRequest(
            markIndex: acceptedMarkCount,
            kind: kind,
            target: target,
            roughPositionInImagePixels: roughPosition,
            spokenWords: trimmedSpokenWords,
            spokenCharacterOffset: spokenCharacterCount
        )))
        acceptedMarkCount += 1
        addSpeech(spokenWords)
        markdownStripper.noteTextSpokenOutsideStripper(spokenWords)
    }

    private mutating func speakWordsWithoutMark(_ spokenWords: String, because reason: DroppedMarkReason) {
        droppedMarks.append(reason)
        addSpeech(spokenWords)
        markdownStripper.noteTextSpokenOutsideStripper(spokenWords)
    }

    /// The spoken field without Markdown or any stray wrapper syntax.
    private static func speakableWords(from spokenField: String) -> String {
        var fieldStripper = SpeechMarkdownStripper(startsAtLineStart: false)
        let withoutMarkdown = fieldStripper.consume(spokenField) + fieldStripper.flush(nextCharacter: nil)
        return withoutMarkdown.replacingOccurrences(of: wrapperOpening, with: "").replacingOccurrences(of: wrapperClosing, with: "")
    }

    private static func parsePosition(_ positionField: String) -> PixelPoint? {
        let coordinates = positionField.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard coordinates.count == 2, let x = Double(coordinates[0]), let y = Double(coordinates[1]), x.isFinite, y.isFinite else { return nil }
        return PixelPoint(x: x, y: y)
    }
}

/// Removes Markdown from speech as it streams: headings, list bullets, emphasis, code
/// backticks, and links. A character that might start Markdown is held until the next
/// one settles it, so the result doesn't depend on where the stream was split.
struct SpeechMarkdownStripper: Sendable {
    private enum HeldText: Sendable {
        case nothing
        case headingMarks
        case bulletMark
        case asteriskRun(characterBeforeRun: Character?)
        case linkText
        case linkAfterClosingBracket
        case linkAddress(linkTextLength: Int)
    }

    private var output = ""
    private var heldCharacters = ""
    private var heldText = HeldText.nothing
    private var isAtLineStart: Bool
    private var previousCharacter: Character?

    private let maximumHeldLinkCharacters = 200

    init(startsAtLineStart: Bool = true) {
        isAtLineStart = startsAtLineStart
    }

    mutating func consume(_ text: String) -> String {
        for character in text { process(character) }
        return takeOutput()
    }

    /// Settles anything held, as if `nextCharacter` came next. Nil means the text ended.
    mutating func flush(nextCharacter: Character?) -> String {
        switch heldText {
        case .nothing:
            break
        case .asteriskRun(let characterBeforeRun):
            settleAsteriskRun(characterBeforeRun: characterBeforeRun, characterAfterRun: nextCharacter)
        case .headingMarks, .bulletMark, .linkText, .linkAfterClosingBracket, .linkAddress:
            releaseHeldCharactersAsText()
        }
        return takeOutput()
    }

    /// Keeps line and emphasis context right when speech was added without going through here.
    mutating func noteTextSpokenOutsideStripper(_ spokenText: String) {
        guard let lastCharacter = spokenText.last else { return }
        previousCharacter = lastCharacter
        isAtLineStart = lastCharacter == "\n"
    }

    private mutating func takeOutput() -> String {
        defer { output = "" }
        return output
    }

    private mutating func emit(_ character: Character) {
        output.append(character)
        isAtLineStart = character == "\n"
    }

    private mutating func releaseHeldCharactersAsText() {
        let charactersToRelease = heldCharacters
        heldCharacters = ""
        heldText = .nothing
        for character in charactersToRelease { emit(character) }
    }

    private mutating func settleAsteriskRun(characterBeforeRun: Character?, characterAfterRun: Character?) {
        // "2 * 3" keeps its asterisk. A run touching a word, like "**bold**", is emphasis.
        let touchesTextBefore = characterBeforeRun.map { !$0.isWhitespace } ?? false
        let touchesTextAfter = characterAfterRun.map { !$0.isWhitespace } ?? false
        if touchesTextBefore || touchesTextAfter {
            heldCharacters = ""
            heldText = .nothing
        } else {
            releaseHeldCharactersAsText()
        }
    }

    private mutating func process(_ character: Character) {
        defer { previousCharacter = character }

        switch heldText {
        case .nothing:
            if isAtLineStart && character == "#" {
                heldCharacters = "#"
                heldText = .headingMarks
            } else if isAtLineStart && (character == "-" || character == "*" || character == "+") {
                heldCharacters = String(character)
                heldText = .bulletMark
            } else if character == "`" {
                return
            } else if character == "*" {
                heldCharacters = "*"
                heldText = .asteriskRun(characterBeforeRun: previousCharacter)
            } else if character == "[" {
                heldCharacters = "["
                heldText = .linkText
            } else {
                emit(character)
            }

        case .headingMarks:
            if character == "#" {
                heldCharacters.append(character)
            } else if character == " " {
                heldCharacters = ""
                heldText = .nothing
                isAtLineStart = false
            } else {
                releaseHeldCharactersAsText()
                process(character)
            }

        case .bulletMark:
            if character == " " {
                heldCharacters = ""
                heldText = .nothing
                isAtLineStart = false
            } else if heldCharacters == "*" {
                // Not a bullet, so it's emphasis that starts a line, like "**Note**".
                heldText = .asteriskRun(characterBeforeRun: nil)
                process(character)
            } else {
                releaseHeldCharactersAsText()
                process(character)
            }

        case .asteriskRun(let characterBeforeRun):
            if character == "*" {
                heldCharacters.append(character)
            } else {
                settleAsteriskRun(characterBeforeRun: characterBeforeRun, characterAfterRun: character)
                process(character)
            }

        case .linkText:
            if character == "]" {
                heldCharacters.append(character)
                heldText = .linkAfterClosingBracket
            } else if character == "\n" || heldCharacters.count >= maximumHeldLinkCharacters {
                releaseHeldCharactersAsText()
                process(character)
            } else {
                heldCharacters.append(character)
            }

        case .linkAfterClosingBracket:
            if character == "(" {
                // "[" plus the text plus "]" came before, so the text is everything between.
                heldText = .linkAddress(linkTextLength: heldCharacters.count - 2)
                heldCharacters.append(character)
            } else {
                releaseHeldCharactersAsText()
                process(character)
            }

        case .linkAddress(let linkTextLength):
            if character == ")" {
                let linkText = heldCharacters.dropFirst().prefix(linkTextLength)
                heldCharacters = ""
                heldText = .nothing
                for linkCharacter in linkText { emit(linkCharacter) }
            } else if character == "\n" || heldCharacters.count >= maximumHeldLinkCharacters * 2 {
                releaseHeldCharactersAsText()
                process(character)
            } else {
                heldCharacters.append(character)
            }
        }
    }
}
