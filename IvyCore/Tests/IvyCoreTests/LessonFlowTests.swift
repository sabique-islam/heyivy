import Testing
@testable import IvyCore

/// One alignment chunk with every character 50 ms long, counted from the stream start.
private func timeline(for spokenText: String, millisecondsPerCharacter: Double = 50) -> SpeechTimeline {
    var speechTimeline = SpeechTimeline()
    let characters = spokenText.map { String($0) }
    speechTimeline.appendChunk(
        AlignedSpeechChunk(
            characters: characters,
            characterStartTimesMilliseconds: characters.indices.map { Double($0) * millisecondsPerCharacter },
            characterDurationsMilliseconds: characters.map { _ in millisecondsPerCharacter }
        ),
        audioSecondsBeforeChunk: 0
    )
    return speechTimeline
}

@Suite struct MarkTimelineTests {
    // "Look at " is 8 characters, so "this" starts at 0.4 s. "the cache" starts at character 30.
    private let spokenText = "Look at this call first, then the cache."

    @Test func aMarkIsDueItsLeadTimeBeforeItsFirstWord() {
        var markTimeline = MarkTimeline<String>(leadSeconds: 0.08)
        markTimeline.addMark(markIndex: 0, spokenCharacterOffset: 8, spokenWords: "this call", payload: "first mark")
        let speechTimeline = timeline(for: spokenText)
        #expect(markTimeline.update(heardContentSeconds: 0.31, speechTimeline: speechTimeline).marksToShow.isEmpty)
        #expect(markTimeline.update(heardContentSeconds: 0.33, speechTimeline: speechTimeline).marksToShow.map(\.payload) == ["first mark"])
    }

    @Test func aMarkIsShownOnlyOnce() {
        var markTimeline = MarkTimeline<String>(leadSeconds: 0)
        markTimeline.addMark(markIndex: 0, spokenCharacterOffset: 8, spokenWords: "this", payload: "a")
        let speechTimeline = timeline(for: spokenText)
        _ = markTimeline.update(heardContentSeconds: 1, speechTimeline: speechTimeline)
        #expect(markTimeline.update(heardContentSeconds: 1.1, speechTimeline: speechTimeline).marksToShow.isEmpty)
    }

    @Test func aSmallOffsetDriftIsCorrectedByFindingTheWord() {
        // The voice stream starts with a space the parser never saw, so offsets can be off by one.
        var markTimeline = MarkTimeline<String>(leadSeconds: 0)
        markTimeline.addMark(markIndex: 0, spokenCharacterOffset: 29, spokenWords: "the cache", payload: "cache")
        let speechTimeline = timeline(for: " " + spokenText)
        #expect(markTimeline.update(heardContentSeconds: 1.54, speechTimeline: speechTimeline).marksToShow.isEmpty)
        #expect(markTimeline.update(heardContentSeconds: 1.55, speechTimeline: speechTimeline).marksToShow.map(\.payload) == ["cache"])
    }

    @Test func aMarkWaitsUntilItsWordHasArrivedFromTheVoiceStream() {
        var markTimeline = MarkTimeline<String>(leadSeconds: 0)
        markTimeline.addMark(markIndex: 0, spokenCharacterOffset: 30, spokenWords: "the cache", payload: "cache")
        let partialTimeline = timeline(for: "Look at this call first, then ")
        #expect(markTimeline.update(heardContentSeconds: 5, speechTimeline: partialTimeline).marksToShow.isEmpty)
        #expect(markTimeline.update(heardContentSeconds: 1.5, speechTimeline: timeline(for: spokenText)).marksToShow.map(\.payload) == ["cache"])
    }

    @Test func aMarkResolvedTooLongAfterItsWordIsDropped() {
        var markTimeline = MarkTimeline<String>(leadSeconds: 0, maximumLatenessSeconds: 1.0)
        markTimeline.addMark(markIndex: 0, spokenCharacterOffset: 8, spokenWords: "this", payload: "late")
        let update = markTimeline.update(heardContentSeconds: 1.5, speechTimeline: timeline(for: spokenText))
        #expect(update.marksToShow.isEmpty)
        #expect(update.marksDroppedAsLate == [0])
    }

    @Test func noMoreThanFiveMarksShowAndTheOldestFadesFirst() {
        var markTimeline = MarkTimeline<Int>(leadSeconds: 0)
        let manyWords = (0..<7).map { "w\($0)" }.joined(separator: " ")
        for markIndex in 0..<7 {
            markTimeline.addMark(markIndex: markIndex, spokenCharacterOffset: markIndex * 3, spokenWords: "w\(markIndex)", payload: markIndex)
        }
        let update = markTimeline.update(heardContentSeconds: 1.0, speechTimeline: timeline(for: manyWords))
        #expect(update.marksToShow.map(\.payload) == [0, 1, 2, 3, 4, 5, 6])
        #expect(update.marksToFade == [0, 1])
        #expect(markTimeline.visibleMarkIndexes == [2, 3, 4, 5, 6])
    }

    @Test func whenTimingsAreUnreliableMarksFallBackToTheirSentenceStart() {
        var speechTimeline = SpeechTimeline()
        speechTimeline.appendChunk(AlignedSpeechChunk(characters: ["A", ".", " "], characterStartTimesMilliseconds: [0, 50, 100], characterDurationsMilliseconds: [50, 50, 50]), audioSecondsBeforeChunk: 0)
        speechTimeline.appendChunk(AlignedSpeechChunk(characters: ["B", "b", " ", "c", "c"], characterStartTimesMilliseconds: [150, 200, 250, 100, 350], characterDurationsMilliseconds: [50, 50, 50, 50, 50]), audioSecondsBeforeChunk: 0.15)
        var markTimeline = MarkTimeline<String>(leadSeconds: 0)
        markTimeline.addMark(markIndex: 0, spokenCharacterOffset: 6, spokenWords: "cc", payload: "cc")
        // "cc" has a broken time, so the mark uses its sentence's start, "Bb" at 0.15 s.
        #expect(markTimeline.update(heardContentSeconds: 0.15, speechTimeline: speechTimeline).marksToShow.map(\.payload) == ["cc"])
    }
}

@Suite struct LessonStateMachineTests {
    @Test func aFullLessonGoesThroughEveryPhaseInOrder() {
        var stateMachine = LessonStateMachine()
        let pressEffects = stateMachine.handle(.keyPressed)
        let lessonID = stateMachine.currentLessonID
        #expect(pressEffects == [.clearMarks, .startListening(lessonID)])
        #expect(stateMachine.phase == .listening)

        #expect(stateMachine.handle(.keyReleased(transcriptIsEmpty: false)) == [.playThinkingCue, .captureScreensAndAsk(lessonID)])
        #expect(stateMachine.phase == .thinking)

        #expect(stateMachine.handle(.firstAudioPlayed(lessonID)) == [])
        #expect(stateMachine.phase == .speaking)

        #expect(stateMachine.handle(.speechFinished(lessonID)) == [.fadeMarksAfterLesson])
        #expect(stateMachine.phase == .finished)
    }

    @Test func releasingWithNothingSaidCancelsQuietly() {
        var stateMachine = LessonStateMachine()
        _ = stateMachine.handle(.keyPressed)
        #expect(stateMachine.handle(.keyReleased(transcriptIsEmpty: true)) == [.stopListening])
        #expect(stateMachine.phase == .cancelled)
    }

    @Test func pressingDuringALessonStopsTheAudioFirstThenStartsANewLesson() {
        var stateMachine = LessonStateMachine()
        _ = stateMachine.handle(.keyPressed)
        let firstLessonID = stateMachine.currentLessonID
        _ = stateMachine.handle(.keyReleased(transcriptIsEmpty: false))
        _ = stateMachine.handle(.firstAudioPlayed(firstLessonID))

        let effects = stateMachine.handle(.keyPressed)
        let secondLessonID = stateMachine.currentLessonID
        #expect(secondLessonID != firstLessonID)
        #expect(effects == [.stopAudio, .cancelLessonWork(firstLessonID), .clearMarks, .startListening(secondLessonID)])
        #expect(stateMachine.phase == .listening)
    }

    @Test func eventsFromAnOldLessonAreIgnored() {
        var stateMachine = LessonStateMachine()
        _ = stateMachine.handle(.keyPressed)
        let oldLessonID = stateMachine.currentLessonID
        _ = stateMachine.handle(.keyReleased(transcriptIsEmpty: false))
        _ = stateMachine.handle(.keyPressed)
        #expect(stateMachine.handle(.firstAudioPlayed(oldLessonID)) == [])
        #expect(stateMachine.handle(.failed(oldLessonID, .answerFailed)) == [])
        #expect(stateMachine.handle(.speechFinished(oldLessonID)) == [])
        #expect(stateMachine.phase == .listening)
    }

    @Test func twentyRapidPressesLeaveOnlyTheLastLessonAliveAndCancelEveryOther() {
        var stateMachine = LessonStateMachine()
        var cancelledLessonIDs: [LessonID] = []
        var startedLessonIDs: [LessonID] = []
        for pressNumber in 0..<20 {
            for effect in stateMachine.handle(.keyPressed) {
                if case .cancelLessonWork(let lessonID) = effect { cancelledLessonIDs.append(lessonID) }
                if case .startListening(let lessonID) = effect { startedLessonIDs.append(lessonID) }
            }
            if pressNumber % 2 == 0 { _ = stateMachine.handle(.keyReleased(transcriptIsEmpty: false)) }
        }
        #expect(Set(startedLessonIDs).count == 20)
        #expect(startedLessonIDs.last == stateMachine.currentLessonID)
        // Every lesson but the last was cancelled, apart from the first, which was idle when pressed again.
        #expect(cancelledLessonIDs == Array(startedLessonIDs.dropLast()))
    }

    @Test func voiceFailingBeforeAnyAudioShowsTheAnswerAsText() {
        var stateMachine = LessonStateMachine()
        _ = stateMachine.handle(.keyPressed)
        let lessonID = stateMachine.currentLessonID
        _ = stateMachine.handle(.keyReleased(transcriptIsEmpty: false))
        #expect(stateMachine.handle(.failed(lessonID, .voiceFailed)) == [.showAnswerAsText, .showMessage(.voiceUnavailable)])
        #expect(stateMachine.phase == .failed(.voiceFailed))
    }

    @Test func voiceFailingMidwayStopsAudioAndMarksAndShowsTheRestAsText() {
        var stateMachine = LessonStateMachine()
        _ = stateMachine.handle(.keyPressed)
        let lessonID = stateMachine.currentLessonID
        _ = stateMachine.handle(.keyReleased(transcriptIsEmpty: false))
        _ = stateMachine.handle(.firstAudioPlayed(lessonID))
        #expect(stateMachine.handle(.failed(lessonID, .voiceFailed)) == [.stopAudio, .stopNewMarks, .showAnswerAsText, .showMessage(.voiceUnavailable)])
    }

    @Test(arguments: [
        (LessonFailure.answerFailed, UserMessage.couldNotGetAnswer),
        (.answerTimedOut, .couldNotGetAnswer),
        (.notAuthorized, .deviceNotAuthorized),
        (.rateLimited, .slowDown),
        (.spendLimitReached, .spendLimitReached),
        (.offline, .offline),
    ])
    func otherFailuresStopEverythingAndExplainWithoutRetrying(failure: LessonFailure, message: UserMessage) {
        var stateMachine = LessonStateMachine()
        _ = stateMachine.handle(.keyPressed)
        let lessonID = stateMachine.currentLessonID
        _ = stateMachine.handle(.keyReleased(transcriptIsEmpty: false))
        let effects = stateMachine.handle(.failed(lessonID, failure))
        #expect(effects == [.stopAudio, .cancelLessonWork(lessonID), .clearMarks, .showMessage(message)])
        #expect(stateMachine.phase == .failed(failure))
    }

    @Test func lockingTheScreenOrUnpluggingADisplayCancelsCleanly() {
        var stateMachine = LessonStateMachine()
        _ = stateMachine.handle(.keyPressed)
        let lessonID = stateMachine.currentLessonID
        _ = stateMachine.handle(.keyReleased(transcriptIsEmpty: false))
        #expect(stateMachine.handle(.screenLockedSleptOrDisplaysChanged) == [.stopAudio, .cancelLessonWork(lessonID), .clearMarks])
        #expect(stateMachine.phase == .cancelled)
        #expect(stateMachine.handle(.screenLockedSleptOrDisplaysChanged) == [.clearMarks])
    }

    @Test func aFailureAfterTheLessonEndedChangesNothing() {
        var stateMachine = LessonStateMachine()
        _ = stateMachine.handle(.keyPressed)
        let lessonID = stateMachine.currentLessonID
        _ = stateMachine.handle(.keyReleased(transcriptIsEmpty: false))
        _ = stateMachine.handle(.firstAudioPlayed(lessonID))
        _ = stateMachine.handle(.speechFinished(lessonID))
        #expect(stateMachine.handle(.failed(lessonID, .answerFailed)) == [])
        #expect(stateMachine.phase == .finished)
    }

    @Test func releasingTheKeyWhenNotListeningDoesNothing() {
        var stateMachine = LessonStateMachine()
        #expect(stateMachine.handle(.keyReleased(transcriptIsEmpty: false)) == [])
        #expect(stateMachine.phase == .idle)
    }
}
