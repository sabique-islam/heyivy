import Foundation

/// A mark that's due to be drawn now.
public struct ScheduledMark<Payload: Sendable & Equatable>: Sendable, Equatable {
    public var markIndex: Int
    public var startSeconds: Double
    public var payload: Payload
}

public struct MarkTimelineUpdate<Payload: Sendable & Equatable>: Sendable, Equatable {
    public var marksToShow: [ScheduledMark<Payload>] = []
    /// Marks to fade because newer ones replaced them.
    public var marksToFade: [Int] = []
    /// Marks whose target was found too long after their words were spoken.
    public var marksDroppedAsLate: [Int] = []
}

/// Decides when each resolved mark appears, from the voice's character timings and the
/// playback clock. The payload is whatever the overlay needs to draw, like a screen rect.
public struct MarkTimeline<Payload: Sendable & Equatable>: Sendable {
    /// Marks appear this long before their word. 80 ms is a starting guess, tuned by ear.
    public var leadSeconds: Double
    /// A mark that would appear this long after its word is dropped, because by then it
    /// points at something the voice has moved on from.
    public var maximumLatenessSeconds: Double
    /// No more than this many show at once, and the oldest fades first.
    public var maximumVisibleMarks: Int

    private struct PendingMark: Sendable {
        var markIndex: Int
        var spokenCharacterOffset: Int
        var spokenWords: String
        var payload: Payload
    }

    private var pendingMarks: [PendingMark] = []
    private var scheduledMarks: [ScheduledMark<Payload>] = []
    public private(set) var visibleMarkIndexes: [Int] = []

    // The voice stream can add or drop a character or two, such as a leading space, so a
    // mark's words are looked for this far either side of where the parser counted them.
    private let searchWindowCharacters = 12

    public init(leadSeconds: Double, maximumLatenessSeconds: Double = 1.0, maximumVisibleMarks: Int = 5) {
        self.leadSeconds = leadSeconds
        self.maximumLatenessSeconds = maximumLatenessSeconds
        self.maximumVisibleMarks = maximumVisibleMarks
    }

    public mutating func addMark(markIndex: Int, spokenCharacterOffset: Int, spokenWords: String, payload: Payload) {
        pendingMarks.append(PendingMark(markIndex: markIndex, spokenCharacterOffset: spokenCharacterOffset, spokenWords: spokenWords, payload: payload))
    }

    public mutating func update(heardContentSeconds: Double, speechTimeline: SpeechTimeline) -> MarkTimelineUpdate<Payload> {
        var timelineUpdate = MarkTimelineUpdate<Payload>()

        // Give each pending mark a time once its words have arrived from the voice stream.
        var marksStillWaiting: [PendingMark] = []
        for pendingMark in pendingMarks {
            guard let startSeconds = startSeconds(of: pendingMark, in: speechTimeline) else {
                marksStillWaiting.append(pendingMark)
                continue
            }
            if heardContentSeconds - startSeconds > maximumLatenessSeconds {
                timelineUpdate.marksDroppedAsLate.append(pendingMark.markIndex)
            } else {
                scheduledMarks.append(ScheduledMark(markIndex: pendingMark.markIndex, startSeconds: startSeconds, payload: pendingMark.payload))
            }
        }
        pendingMarks = marksStillWaiting

        scheduledMarks.sort { $0.startSeconds < $1.startSeconds }
        // Floating-point seconds can land a hair short of an exact tie.
        let comparisonToleranceSeconds = 1e-9
        while let nextMark = scheduledMarks.first, heardContentSeconds + leadSeconds + comparisonToleranceSeconds >= nextMark.startSeconds {
            scheduledMarks.removeFirst()
            timelineUpdate.marksToShow.append(nextMark)
            visibleMarkIndexes.append(nextMark.markIndex)
        }
        while visibleMarkIndexes.count > maximumVisibleMarks {
            timelineUpdate.marksToFade.append(visibleMarkIndexes.removeFirst())
        }
        return timelineUpdate
    }

    /// Nil while the mark's words haven't arrived yet.
    private func startSeconds(of pendingMark: PendingMark, in speechTimeline: SpeechTimeline) -> Double? {
        let spokenCharacters = speechTimeline.spokenCharacters
        let wordCharacters = pendingMark.spokenWords.lowercased().map { String($0) }
        let windowEnd = pendingMark.spokenCharacterOffset + searchWindowCharacters + wordCharacters.count
        let wordsCanStillArrive = !speechTimeline.hasFinished && spokenCharacters.count < windowEnd
        let anchorIndex: Int

        if let foundIndex = nearestOccurrence(of: wordCharacters, in: spokenCharacters, near: pendingMark.spokenCharacterOffset) {
            anchorIndex = foundIndex
        } else if wordsCanStillArrive {
            return nil
        } else if spokenCharacters.isEmpty {
            return speechTimeline.hasFinished ? 0 : nil
        } else {
            // The voice changed the words, say by reading out a number. Use the counted position.
            anchorIndex = min(pendingMark.spokenCharacterOffset, spokenCharacters.count - 1)
        }

        // If any timing went backwards, word times can't be trusted, so mark at the sentence start.
        let timeIndex = speechTimeline.hasUnreliableTimings
            ? sentenceStartIndex(before: anchorIndex, in: spokenCharacters)
            : anchorIndex
        return speechTimeline.characterStartSeconds[timeIndex]
    }

    private func nearestOccurrence(of wordCharacters: [String], in spokenCharacters: [String], near expectedIndex: Int) -> Int? {
        guard !wordCharacters.isEmpty else { return nil }
        let lowestStart = max(0, expectedIndex - searchWindowCharacters)
        let highestStart = min(spokenCharacters.count - wordCharacters.count, expectedIndex + searchWindowCharacters)
        guard lowestStart <= highestStart else { return nil }
        let matchingStarts = (lowestStart...highestStart).filter { startIndex in
            // A match has to start a word, so "the" doesn't match inside "then".
            let startsAWord = startIndex == 0 || spokenCharacters[startIndex - 1].allSatisfy { !$0.isLetter && !$0.isNumber }
            return startsAWord && zip(spokenCharacters[startIndex...], wordCharacters).allSatisfy { $0.lowercased() == $1 }
        }
        return matchingStarts.min { abs($0 - expectedIndex) < abs($1 - expectedIndex) }
    }

    private func sentenceStartIndex(before anchorIndex: Int, in spokenCharacters: [String]) -> Int {
        var index = anchorIndex
        while index > 0 && !".!?".contains(spokenCharacters[index - 1]) { index -= 1 }
        while index < anchorIndex && spokenCharacters[index].allSatisfy(\.isWhitespace) { index += 1 }
        return index
    }
}

// MARK: - Lesson state

/// Each key press starts a new lesson. Streams, audio, and marks carry its ID, so anything
/// still arriving from an older lesson can be recognised and ignored.
public struct LessonID: Sendable, Hashable, CustomStringConvertible {
    public let value: Int
    public var description: String { "lesson \(value)" }
}

public enum LessonFailure: Sendable, Equatable {
    case voiceFailed
    case answerFailed
    case answerTimedOut
    case notAuthorized
    case rateLimited
    case spendLimitReached
    case offline
}

public enum LessonPhase: Sendable, Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case finished
    case cancelled
    case failed(LessonFailure)

    var isActive: Bool {
        self == .listening || self == .thinking || self == .speaking
    }
}

public enum UserMessage: Sendable, Equatable {
    case voiceUnavailable
    case couldNotGetAnswer
    case deviceNotAuthorized
    case slowDown
    case spendLimitReached
    case offline
}

public enum LessonEvent: Sendable, Equatable {
    case keyPressed
    case keyReleased(transcriptIsEmpty: Bool)
    case firstAudioPlayed(LessonID)
    case speechFinished(LessonID)
    case failed(LessonID, LessonFailure)
    case screenLockedSleptOrDisplaysChanged
}

/// What the app should do in response. The state machine decides; the app carries it out.
public enum LessonEffect: Sendable, Equatable {
    case startListening(LessonID)
    case stopListening
    case playThinkingCue
    case captureScreensAndAsk(LessonID)
    /// Stop speech immediately. Always the first effect of an interrupt, so silence comes first.
    case stopAudio
    /// Cancel the lesson's Claude request, voice connection, and pending marks.
    case cancelLessonWork(LessonID)
    case clearMarks
    /// Stop drawing new marks but leave the ones showing.
    case stopNewMarks
    case fadeMarksAfterLesson
    case showAnswerAsText
    case showMessage(UserMessage)
}

/// The single owner of a lesson's phase. No failure is silent, and nothing here retries:
/// a failure shows a message and stops.
public struct LessonStateMachine: Sendable {
    public private(set) var phase = LessonPhase.idle
    public private(set) var currentLessonID = LessonID(value: 0)

    public init() {}

    public mutating func handle(_ event: LessonEvent) -> [LessonEffect] {
        switch event {
        case .keyPressed:
            var effects: [LessonEffect] = []
            if phase.isActive {
                effects += [.stopAudio, .cancelLessonWork(currentLessonID)]
            }
            currentLessonID = LessonID(value: currentLessonID.value + 1)
            phase = .listening
            return effects + [.clearMarks, .startListening(currentLessonID)]

        case .keyReleased(let transcriptIsEmpty):
            guard phase == .listening else { return [] }
            if transcriptIsEmpty {
                phase = .cancelled
                return [.stopListening]
            }
            phase = .thinking
            return [.playThinkingCue, .captureScreensAndAsk(currentLessonID)]

        case .firstAudioPlayed(let lessonID):
            guard lessonID == currentLessonID, phase == .thinking else { return [] }
            phase = .speaking
            return []

        case .speechFinished(let lessonID):
            guard lessonID == currentLessonID, phase == .thinking || phase == .speaking else { return [] }
            phase = .finished
            return [.fadeMarksAfterLesson]

        case .failed(let lessonID, let failure):
            guard lessonID == currentLessonID, phase.isActive else { return [] }
            return handleFailure(failure)

        case .screenLockedSleptOrDisplaysChanged:
            guard phase.isActive else { return [.clearMarks] }
            phase = .cancelled
            return [.stopAudio, .cancelLessonWork(currentLessonID), .clearMarks]
        }
    }

    private mutating func handleFailure(_ failure: LessonFailure) -> [LessonEffect] {
        let phaseBeforeFailure = phase
        phase = .failed(failure)
        switch failure {
        case .voiceFailed where phaseBeforeFailure == .speaking:
            // Audio stops, the rest of the answer appears as text, and no more marks start.
            return [.stopAudio, .stopNewMarks, .showAnswerAsText, .showMessage(.voiceUnavailable)]
        case .voiceFailed:
            return [.showAnswerAsText, .showMessage(.voiceUnavailable)]
        case .answerFailed, .answerTimedOut:
            return stopEverything(andShow: .couldNotGetAnswer)
        case .notAuthorized:
            return stopEverything(andShow: .deviceNotAuthorized)
        case .rateLimited:
            return stopEverything(andShow: .slowDown)
        case .spendLimitReached:
            return stopEverything(andShow: .spendLimitReached)
        case .offline:
            return stopEverything(andShow: .offline)
        }
    }

    private func stopEverything(andShow message: UserMessage) -> [LessonEffect] {
        [.stopAudio, .cancelLessonWork(currentLessonID), .clearMarks, .showMessage(message)]
    }
}
