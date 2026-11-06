import Testing
@testable import IvyCore

/// One alignment chunk where every character lasts the same time, like ElevenLabs sends.
private func alignedChunk(_ text: String, firstStartMilliseconds: Double, millisecondsPerCharacter: Double = 50) -> AlignedSpeechChunk {
    let characters = text.map { String($0) }
    return AlignedSpeechChunk(
        characters: characters,
        characterStartTimesMilliseconds: characters.indices.map { firstStartMilliseconds + Double($0) * millisecondsPerCharacter },
        characterDurationsMilliseconds: characters.map { _ in millisecondsPerCharacter }
    )
}

@Suite struct SpeechTimelineTests {
    @Test func timingsAlreadyCountedFromTheStreamStartAreKept() {
        var timeline = SpeechTimeline()
        timeline.appendChunk(alignedChunk("Hi there ", firstStartMilliseconds: 0), audioSecondsBeforeChunk: 0)
        timeline.appendChunk(alignedChunk("friend.", firstStartMilliseconds: 450), audioSecondsBeforeChunk: 0.45)
        timeline.finishStream()

        #expect(timeline.words.map(\.text) == ["Hi", "there", "friend."])
        #expect(timeline.words.map(\.startSeconds) == [0, 0.15, 0.45])
        #expect(timeline.chunkTimeBases == [.countedFromStreamStart, .countedFromStreamStart])
        #expect(timeline.issues.isEmpty)
    }

    @Test func timingsCountedFromEachChunkAreShiftedByTheAudioBeforeIt() {
        var timeline = SpeechTimeline()
        timeline.appendChunk(alignedChunk("Hi there ", firstStartMilliseconds: 0), audioSecondsBeforeChunk: 0)
        timeline.appendChunk(alignedChunk("friend.", firstStartMilliseconds: 0), audioSecondsBeforeChunk: 0.45)
        timeline.finishStream()

        #expect(timeline.words.last?.startSeconds == 0.45)
        #expect(timeline.chunkTimeBases.last == .countedFromChunkStart)
        #expect(timeline.issues.isEmpty)
    }

    @Test func aWordSplitAcrossChunksKeepsTheStartOfItsFirstCharacter() {
        var timeline = SpeechTimeline()
        timeline.appendChunk(alignedChunk("Hel", firstStartMilliseconds: 0), audioSecondsBeforeChunk: 0)
        timeline.appendChunk(alignedChunk("lo world", firstStartMilliseconds: 150), audioSecondsBeforeChunk: 0.15)
        timeline.finishStream()

        #expect(timeline.words.map(\.text) == ["Hello", "world"])
        #expect(timeline.words.first?.startSeconds == 0)
        #expect(timeline.words.first?.endSeconds == 0.25)
    }

    @Test func aWordIsAvailableAsSoonAsItsFirstCharacterArrives() {
        var timeline = SpeechTimeline()
        timeline.appendChunk(alignedChunk("Hel", firstStartMilliseconds: 0), audioSecondsBeforeChunk: 0)
        #expect(timeline.words.map(\.text) == ["Hel"])
    }

    @Test func repeatedSpacesDoNotMakeEmptyWords() {
        var timeline = SpeechTimeline()
        timeline.appendChunk(alignedChunk(" one  two ", firstStartMilliseconds: 0), audioSecondsBeforeChunk: 0)
        timeline.finishStream()
        #expect(timeline.words.map(\.text) == ["one", "two"])
        #expect(timeline.words.map(\.wordIndex) == [0, 1])
    }

    @Test func timingsThatGoBackwardsAreReported() {
        var timeline = SpeechTimeline()
        timeline.appendChunk(alignedChunk("abc ", firstStartMilliseconds: 500), audioSecondsBeforeChunk: 0)
        timeline.appendChunk(alignedChunk("def", firstStartMilliseconds: 600), audioSecondsBeforeChunk: 0.7)
        #expect(timeline.issues == [.timingsWentBackwards(characterIndex: 4)])
    }

    @Test func spokenTextThatDiffersFromTheSentTextIsReported() {
        var timeline = SpeechTimeline()
        timeline.appendChunk(alignedChunk("Hi there", firstStartMilliseconds: 0), audioSecondsBeforeChunk: 0)
        timeline.finishStream()
        #expect(timeline.checkSpokenTextMatches(sentText: "Hi there") == true)
        #expect(timeline.checkSpokenTextMatches(sentText: "Hello there") == false)
        #expect(timeline.issues == [.spokenTextDiffersFromSentText])
    }

    @Test func leadingAndTrailingSpacesDoNotCountAsAMismatch() {
        var timeline = SpeechTimeline()
        timeline.appendChunk(alignedChunk(" Hi there ", firstStartMilliseconds: 0), audioSecondsBeforeChunk: 0)
        #expect(timeline.checkSpokenTextMatches(sentText: "Hi there") == true)
    }
}

@Suite struct PlaybackClockTests {
    /// Records a sample every 10 ms between two host times, rendering at real speed or frozen.
    private func recordSamples(
        into clock: inout PlaybackClock,
        fromHostSeconds startHostSeconds: Double,
        toHostSeconds endHostSeconds: Double,
        renderedAtStart: Double,
        isAdvancing: Bool
    ) -> Double {
        var hostSeconds = startHostSeconds
        var renderedSeconds = renderedAtStart
        while hostSeconds <= endHostSeconds + 1e-9 {
            clock.recordRenderedPosition(hostSeconds: hostSeconds, renderedContentSeconds: renderedSeconds, isAdvancing: isAdvancing)
            hostSeconds += 0.01
            if isAdvancing { renderedSeconds += 0.01 }
        }
        return renderedSeconds - (isAdvancing ? 0.01 : 0)
    }

    @Test func nothingIsHeardBeforePlaybackStarts() {
        let clock = PlaybackClock(outputLatencySeconds: 0.2)
        #expect(clock.heardContentSeconds(atHostSeconds: 100) == 0)
    }

    @Test func whatIsHeardNowIsWhatWasRenderedOneOutputDelayAgo() {
        var clock = PlaybackClock(outputLatencySeconds: 0.2)
        _ = recordSamples(into: &clock, fromHostSeconds: 1, toHostSeconds: 3, renderedAtStart: 0, isAdvancing: true)
        #expect(abs(clock.heardContentSeconds(atHostSeconds: 2.5) - 1.3) < 1e-6)
        #expect(clock.heardContentSeconds(atHostSeconds: 1.1) == 0)
    }

    @Test func afterAPauseTheAudioAlreadyOnItsWayIsStillHeardThenTheClockFreezes() {
        var clock = PlaybackClock(outputLatencySeconds: 0.2)
        let renderedAtPause = recordSamples(into: &clock, fromHostSeconds: 1, toHostSeconds: 2, renderedAtStart: 0, isAdvancing: true)
        _ = recordSamples(into: &clock, fromHostSeconds: 2.01, toHostSeconds: 3, renderedAtStart: renderedAtPause, isAdvancing: false)
        _ = recordSamples(into: &clock, fromHostSeconds: 3.01, toHostSeconds: 4, renderedAtStart: renderedAtPause, isAdvancing: true)

        #expect(abs(clock.heardContentSeconds(atHostSeconds: 2.1) - 0.9) < 1e-6)
        #expect(abs(clock.heardContentSeconds(atHostSeconds: 2.25) - 1.0) < 1e-6)
        #expect(abs(clock.heardContentSeconds(atHostSeconds: 3.1) - 1.0) < 1e-6)
        #expect(abs(clock.heardContentSeconds(atHostSeconds: 3.31) - 1.1) < 0.011)
    }

    @Test func aFutureFramesTimeIsPredictedWhilePlaying() {
        var clock = PlaybackClock(outputLatencySeconds: 0.05)
        _ = recordSamples(into: &clock, fromHostSeconds: 1, toHostSeconds: 2, renderedAtStart: 0, isAdvancing: true)
        // The last sample is at host 2.0, rendered 1.0. A frame shown at 2.06 hears 1.01.
        #expect(abs(clock.heardContentSeconds(atHostSeconds: 2.06) - 1.01) < 1e-6)
    }

    @Test func aFutureFramesTimeIsNotPredictedWhilePaused() {
        var clock = PlaybackClock(outputLatencySeconds: 0.05)
        _ = recordSamples(into: &clock, fromHostSeconds: 1, toHostSeconds: 2, renderedAtStart: 0.5, isAdvancing: false)
        #expect(clock.heardContentSeconds(atHostSeconds: 5) == 0.5)
    }

    @Test func heardTimeNeverGoesBackwards() {
        var clock = PlaybackClock(outputLatencySeconds: 0.1)
        _ = recordSamples(into: &clock, fromHostSeconds: 1, toHostSeconds: 2, renderedAtStart: 0, isAdvancing: true)
        var previousHeardSeconds = 0.0
        for step in 0..<400 {
            let heardSeconds = clock.heardContentSeconds(atHostSeconds: 1 + Double(step) * 0.0037)
            #expect(heardSeconds >= previousHeardSeconds)
            previousHeardSeconds = heardSeconds
        }
    }

    @Test func oldSamplesAreDroppedButRecentHistoryStaysCorrect() {
        var clock = PlaybackClock(outputLatencySeconds: 0.2)
        _ = recordSamples(into: &clock, fromHostSeconds: 1, toHostSeconds: 60, renderedAtStart: 0, isAdvancing: true)
        #expect(clock.recordedSampleCount < 1000)
        #expect(abs(clock.heardContentSeconds(atHostSeconds: 59.5) - 58.3) < 1e-6)
    }
}

@Suite struct PlaybackStallGuardTests {
    @Test func playbackStartsOnceAShortBufferIsReady() {
        var stallGuard = PlaybackStallGuard()
        #expect(stallGuard.decide(bufferedAheadSeconds: 0.1, streamHasEnded: false) == .keepWaiting)
        #expect(stallGuard.decide(bufferedAheadSeconds: 0.15, streamHasEnded: false) == .startPlaying)
        #expect(stallGuard.isPlaying)
    }

    @Test func playbackPausesBeforeTheQueueRunsDryAndCountsTheStall() {
        var stallGuard = PlaybackStallGuard()
        _ = stallGuard.decide(bufferedAheadSeconds: 0.2, streamHasEnded: false)
        #expect(stallGuard.decide(bufferedAheadSeconds: 0.07, streamHasEnded: false) == .keepPlaying)
        #expect(stallGuard.decide(bufferedAheadSeconds: 0.05, streamHasEnded: false) == .pauseForMoreAudio)
        #expect(stallGuard.stallCount == 1)
    }

    @Test func afterAStallPlaybackWaitsForALargerBuffer() {
        var stallGuard = PlaybackStallGuard()
        _ = stallGuard.decide(bufferedAheadSeconds: 0.2, streamHasEnded: false)
        _ = stallGuard.decide(bufferedAheadSeconds: 0.01, streamHasEnded: false)
        #expect(stallGuard.decide(bufferedAheadSeconds: 0.2, streamHasEnded: false) == .keepWaiting)
        #expect(stallGuard.decide(bufferedAheadSeconds: 0.3, streamHasEnded: false) == .startPlaying)
    }

    @Test func onceTheStreamHasEndedTheRestPlaysOutWithoutPausing() {
        var stallGuard = PlaybackStallGuard()
        #expect(stallGuard.decide(bufferedAheadSeconds: 0.05, streamHasEnded: true) == .startPlaying)
        #expect(stallGuard.decide(bufferedAheadSeconds: 0.01, streamHasEnded: true) == .keepPlaying)
        #expect(stallGuard.stallCount == 0)
    }

    @Test func anEndedStreamWithNothingLeftDoesNotStart() {
        var stallGuard = PlaybackStallGuard()
        #expect(stallGuard.decide(bufferedAheadSeconds: 0, streamHasEnded: true) == .keepWaiting)
    }
}

@Suite struct WordCueSchedulerTests {
    private let words = [
        SpokenWord(text: "one", startSeconds: 0.5, endSeconds: 0.7, wordIndex: 0),
        SpokenWord(text: "two", startSeconds: 1.0, endSeconds: 1.2, wordIndex: 1),
        SpokenWord(text: "three", startSeconds: 1.5, endSeconds: 1.8, wordIndex: 2),
    ]

    @Test func aWordIsDueItsLeadTimeBeforeItIsHeard() {
        var scheduler = WordCueScheduler(leadSeconds: 0.08)
        #expect(scheduler.takeDueWords(from: words, heardContentSeconds: 0.41).isEmpty)
        #expect(scheduler.takeDueWords(from: words, heardContentSeconds: 0.42).map(\.text) == ["one"])
    }

    @Test func eachWordIsDueOnlyOnce() {
        var scheduler = WordCueScheduler(leadSeconds: 0)
        _ = scheduler.takeDueWords(from: words, heardContentSeconds: 0.6)
        #expect(scheduler.takeDueWords(from: words, heardContentSeconds: 0.6).isEmpty)
    }

    @Test func everyWordPassedSinceTheLastCheckIsReturnedInOrder() {
        var scheduler = WordCueScheduler(leadSeconds: 0)
        #expect(scheduler.takeDueWords(from: words, heardContentSeconds: 2).map(\.text) == ["one", "two", "three"])
    }

    @Test func wordsThatArriveLaterAreStillScheduled() {
        var scheduler = WordCueScheduler(leadSeconds: 0)
        _ = scheduler.takeDueWords(from: Array(words.prefix(1)), heardContentSeconds: 2)
        #expect(scheduler.takeDueWords(from: words, heardContentSeconds: 2).map(\.text) == ["two", "three"])
    }
}
