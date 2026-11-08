import Foundation

/// A mark that was drawn in an earlier answer, kept so a follow-up like "why that one?" can
/// be understood. Only marks the user actually saw are kept. They last for the session, in
/// memory, and are never saved or logged.
public struct PastMark: Sendable, Equatable {
    public var kind: MarkKind
    /// The words that were being said as it appeared.
    public var spokenWords: String
    public var target: MarkTarget

    public init(kind: MarkKind, spokenWords: String, target: MarkTarget) {
        self.kind = kind
        self.spokenWords = spokenWords
        self.target = target
    }
}

/// Describes earlier answers' marks to Claude, alongside a follow-up question.
public enum LessonMemory {
    /// Older answers drop off first, so a long session can't grow the request without limit.
    public static let mostAnswersDescribed = 3

    /// One line per answer that drew something, oldest first, numbered by its place among
    /// all the earlier answers. Nil when no earlier answer drew anything, so nothing is sent.
    public static func describeMarks(fromEarlierAnswers marksByAnswer: [[PastMark]]) -> String? {
        let answerCount = marksByAnswer.count
        let firstDescribedAnswerIndex = max(0, answerCount - mostAnswersDescribed)
        var answerLines: [String] = []
        for answerIndex in firstDescribedAnswerIndex..<answerCount {
            let marks = marksByAnswer[answerIndex]
            guard !marks.isEmpty else { continue }
            let markDescriptions = marks.map(describe).joined(separator: "; ")
            answerLines.append("Answer \(answerIndex + 1) of \(answerCount): \(markDescriptions).")
        }
        guard !answerLines.isEmpty else { return nil }
        return """
        In your earlier answers you drew these marks on the screen, so a follow-up like "that one" may mean one of them. \
        The screen may have changed since.
        \(answerLines.joined(separator: "\n"))
        """
    }

    static func describe(_ pastMark: PastMark) -> String {
        let whatItMarked: String
        switch pastMark.target {
        case .visibleText(let words): whatItMarked = "on \(quoted(words.joined(separator: " ")))"
        case .nonText: whatItMarked = "on something without text"
        case .labelText(let text): whatItMarked = "reading \(quoted(text))"
        }
        let action: String
        switch pastMark.kind {
        case .circle: action = "a circle"
        case .underline: action = "an underline"
        case .highlight: action = "a highlight"
        case .arrow: action = "an arrow"
        case .label: action = "a label"
        }
        return "\(action) \(whatItMarked), while saying \(quoted(pastMark.spokenWords))"
    }

    /// The words came from the screen and Claude's own script, so they're cut short and kept
    /// on one line, inside quotes they can't close.
    static func quoted(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
        let shortened = oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
        return "\"\(shortened)\""
    }
}
