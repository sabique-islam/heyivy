import Testing
@testable import IvyCore

/// Feeds a script in the given pieces and collects everything the parser produces.
private func parse(_ pieces: [String], limits: LessonScriptLimits = LessonScriptLimits()) -> (speech: String, marks: [MarkRequest], parser: LessonScriptParser) {
    var parser = LessonScriptParser(limits: limits)
    var outputs: [ScriptParserOutput] = []
    for piece in pieces { outputs += parser.consume(piece) }
    outputs += parser.finish()
    var speech = ""
    var marks: [MarkRequest] = []
    for output in outputs {
        switch output {
        case .speech(let spokenText): speech += spokenText
        case .mark(let markRequest):
            // A mark's offset must point at where its words start in the speech so far.
            #expect(markRequest.spokenCharacterOffset == speech.count)
            marks.append(markRequest)
        }
    }
    return (speech, marks, parser)
}

private func parseWhole(_ script: String) -> (speech: String, marks: [MarkRequest], parser: LessonScriptParser) {
    parse([script])
}

@Suite struct LessonScriptParserTests {
    @Test func plainTextIsSpokenAsIs() {
        #expect(parseWhole("The loop starts at zero.").speech == "The loop starts at zero.")
    }

    @Test func aWrappedPhraseIsSpokenAndBecomesAMark() {
        let result = parseWhole("Look at {{this call|underline|fibonacci(n|612,118}} first.")
        #expect(result.speech == "Look at this call first.")
        #expect(result.marks == [
            MarkRequest(
                markIndex: 0,
                kind: .underline,
                target: .visibleText(words: ["fibonacci(n"]),
                roughPositionInImagePixels: PixelPoint(x: 612, y: 118),
                spokenWords: "this call",
                spokenCharacterOffset: 8
            ),
        ])
    }

    @Test func aDashMeansTheTargetHasNoText() {
        let result = parseWhole("{{That icon|circle|-|40,50}} saves it.")
        #expect(result.marks.first?.target == .nonText)
    }

    @Test func allMarkKindsAreRecognised() {
        let script = MarkKind.allCases.map { "{{w\($0.rawValue)|\($0.rawValue)|x|1,2}} " }.joined()
        #expect(parseWhole(script).marks.map(\.kind) == MarkKind.allCases)
    }

    @Test func aPipeInsideTheTargetTextIsKeptInTheTarget() {
        let result = parseWhole("{{the pipe|highlight|a | b|10,20}}")
        #expect(result.marks.first?.target == .visibleText(words: ["a", "|", "b"]))
        #expect(result.speech == "the pipe")
    }

    @Test func singleBracesAndPipesFromCodeAreSpokenAndDoNotBreakParsing() {
        let result = parseWhole("In map { x | x } we see {{the body|underline|x|5,5}} here.")
        #expect(result.speech == "In map { x | x } we see the body here.")
        #expect(result.marks.count == 1)
    }

    @Test func anUnknownKindKeepsTheWordsAndDropsTheMark() {
        let result = parseWhole("See {{this bit|sparkle|x|1,1}} now.")
        #expect(result.speech == "See this bit now.")
        #expect(result.marks.isEmpty)
        #expect(result.parser.droppedMarks == [.unknownKind])
    }

    @Test func aBadPositionKeepsTheWordsAndDropsTheMark() {
        let result = parseWhole("See {{this bit|circle|x|left side}} now.")
        #expect(result.speech == "See this bit now.")
        #expect(result.parser.droppedMarks == [.invalidPosition])
    }

    @Test func tooFewFieldsKeepTheWordsAndDropTheMark() {
        let result = parseWhole("See {{this bit|circle}} now.")
        #expect(result.speech == "See this bit now.")
        #expect(result.parser.droppedMarks == [.malformed])
    }

    @Test func anEmptyWrapperSpeaksNothing() {
        let result = parseWhole("A{{}}B")
        #expect(result.speech == "AB")
    }

    @Test func anUnclosedWrapperIsSpokenWithoutItsSyntaxAfter200Characters() {
        let longTail = String(repeating: "word ", count: 50)
        let result = parseWhole("Start {{this part|circle" + longTail)
        #expect(result.speech.hasPrefix("Start this part"))
        #expect(!result.speech.contains("{{"))
        #expect(!result.speech.contains("|circle"))
        #expect(result.marks.isEmpty)
    }

    @Test func anUnclosedWrapperAtTheEndOfTheReplyKeepsItsWords() {
        let result = parseWhole("Start {{this part|circle|x|1")
        #expect(result.speech == "Start this part")
        #expect(result.parser.droppedMarks == [.malformed])
    }

    @Test(arguments: [197, 198, 199, 200])
    func aWrapperClosingRightAtTheHoldLimitIsTheSameWhetherStreamedOrWhole(contentLength: Int) {
        let fields = "this|circle|x|1,1"
        let script = "A {{" + fields + String(repeating: " ", count: contentLength - fields.count) + "}} B"
        let whole = parseWhole(script)
        let oneCharacterAtATime = parse(script.map { String($0) })
        #expect(oneCharacterAtATime.speech == whole.speech)
        #expect(oneCharacterAtATime.marks == whole.marks)
        #expect(whole.marks.count == (contentLength <= 200 ? 1 : 0))
    }

    @Test func textHeldBackInAWrapperIsReleasedAsSoonAsItClosesNotAtTheEnd() {
        var parser = LessonScriptParser()
        _ = parser.consume("Look {{at this|circle|x|")
        let outputs = parser.consume("1,1}} now")
        #expect(outputs.contains { if case .mark = $0 { return true } else { return false } })
    }

    @Test func plainSpeechIsNotHeldBack() {
        var parser = LessonScriptParser()
        let outputs = parser.consume("Hello there")
        #expect(outputs == [.speech("Hello there")])
    }

    @Test func onlyFiveMarksAreKeptAndTheRestAreSpokenPlainly() {
        let script = (0..<7).map { "{{word\($0)|circle|word\($0)|1,1}} " }.joined()
        let result = parseWhole(script)
        #expect(result.marks.count == 5)
        #expect(result.marks.map(\.markIndex) == [0, 1, 2, 3, 4])
        #expect(result.speech == (0..<7).map { "word\($0) " }.joined())
        #expect(result.parser.droppedMarks == [.tooManyMarks, .tooManyMarks])
    }

    @Test func targetTextIsCappedAtThreeWords() {
        let result = parseWhole("{{it|underline|one two three four five|1,1}}")
        #expect(result.marks.first?.target == .visibleText(words: ["one", "two", "three"]))
    }

    @Test func labelTextIsCappedAt24Characters() {
        let result = parseWhole("{{this|label|an extremely long label that goes on|1,1}}")
        guard case .labelText(let labelText)? = result.marks.first?.target else {
            Issue.record("expected label text")
            return
        }
        #expect(labelText.count <= 24)
        #expect(labelText.hasPrefix("an extremely long"))
    }

    @Test func markdownIsNotSpoken() {
        let result = parseWhole("# Title\n**Bold** and *soft* and `code` and [a link](https://x.y).\n- one\n- two")
        #expect(result.speech == "Title\nBold and soft and code and a link.\none\ntwo")
    }

    @Test func aMultiplicationSignBetweenSpacesIsKept() {
        #expect(parseWhole("It is 2 * 3 here.").speech == "It is 2 * 3 here.")
    }

    @Test func markdownInsideTheSpokenWordsOfAWrapperIsNotSpoken() {
        let result = parseWhole("See {{**the** cache|circle|cache|1,1}}.")
        #expect(result.speech == "See the cache.")
        #expect(result.marks.first?.spokenWords == "the cache")
    }
}

/// Tags were split across stream chunks in every test reply, so splitting at any point
/// must give exactly the same result as reading the whole script at once.
@Suite struct LessonScriptParserSplitTests {
    static let scripts = [
        "Look at {{this call|underline|fibonacci(n|612,118}} first, then {{the cache|circle|cache|540,190}}.",
        "**Note:** {{That icon|circle|-|40,50}} saves {{it|label|Save|90,10}}, see `x` and { y | z }.",
        "Start {{this part|circle|x|1",
        "{{a|circle|a|1,1}}{{b|circle|b|2,2}}{{c|arrow|c|3,3}}",
        "Edge }} and {{ unopened |bars| and [link](u) * 2 * 3",
        "# Head\n- item {{one|highlight|one|9,9}}\n- two",
    ]

    @Test(arguments: scripts)
    func splittingAtAnyOnePointChangesNothing(script: String) {
        let whole = parseWhole(script)
        let characters = Array(script)
        for splitIndex in 0...characters.count {
            let pieces = [String(characters[..<splitIndex]), String(characters[splitIndex...])]
            let split = parse(pieces)
            #expect(split.speech == whole.speech, "split at \(splitIndex)")
            #expect(split.marks == whole.marks, "split at \(splitIndex)")
        }
    }

    @Test(arguments: scripts)
    func feedingOneCharacterAtATimeChangesNothing(script: String) {
        let whole = parseWhole(script)
        let oneCharacterAtATime = parse(script.map { String($0) })
        #expect(oneCharacterAtATime.speech == whole.speech)
        #expect(oneCharacterAtATime.marks == whole.marks)
    }
}

/// Random input must never crash the parser, leak syntax into speech, or break its limits.
@Suite struct LessonScriptParserFuzzTests {
    private struct SeededRandomNumberGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test func randomScriptsNeverLeakWrapperSyntaxOrBreakLimits() {
        var randomNumbers = SeededRandomNumberGenerator(state: 42)
        let fragments = ["{{", "}}", "|", "{", "}", "circle", "underline", "-", "12,34", "word ", "*", "**", "`", "#", "\n", "[", "](", ")", "λ", "≤", "é", " ", "x"]
        for _ in 0..<2000 {
            let script = (0..<Int.random(in: 1...40, using: &randomNumbers)).map { _ in fragments.randomElement(using: &randomNumbers)! }.joined()
            var remaining = Substring(script)
            var pieces: [String] = []
            while !remaining.isEmpty {
                let pieceLength = Int.random(in: 1...8, using: &randomNumbers)
                pieces.append(String(remaining.prefix(pieceLength)))
                remaining = remaining.dropFirst(pieceLength)
            }
            let result = parse(pieces)
            #expect(result.marks.count <= 5)
            for mark in result.marks {
                #expect(!mark.spokenWords.contains("{{") && !mark.spokenWords.contains("}}"))
            }
            // Every "{{" opens a wrapper, so wrapper syntax can never reach speech.
            #expect(!result.speech.contains("{{"))
        }
    }

    /// The strongest check: for random scripts, random splits give exactly what reading
    /// the whole script gives. This is what makes split tags safe in practice.
    @Test func randomSplitsOfRandomScriptsMatchReadingThemWhole() {
        var randomNumbers = SeededRandomNumberGenerator(state: 7)
        let fragments = ["{{", "}}", "|", "{", "}", "circle", "label", "-", "1,2", "a b ", "*", "**", "`", "#", "# ", "\n", "\n- ", "[", "]", "](", ")", "é", " ", "x"]
        var scriptsChecked = 0
        for _ in 0..<5000 {
            let script = (0..<Int.random(in: 1...60, using: &randomNumbers)).map { _ in fragments.randomElement(using: &randomNumbers)! }.joined()
            var remaining = Substring(script)
            var pieces: [String] = []
            while !remaining.isEmpty {
                let pieceLength = Int.random(in: 1...6, using: &randomNumbers)
                pieces.append(String(remaining.prefix(pieceLength)))
                remaining = remaining.dropFirst(pieceLength)
            }
            let whole = parseWhole(script)
            let split = parse(pieces)
            #expect(split.speech == whole.speech, "script: \(script.debugDescription)")
            #expect(split.marks == whole.marks, "script: \(script.debugDescription)")
            scriptsChecked += 1
        }
        #expect(scriptsChecked == 5000)
    }
}
