import Foundation

/// Answers "how far into the speech has the listener heard?" for any moment, including
/// the moment a future screen frame will appear.
///
/// The player reports how much audio it has rendered, but rendered audio still has to
/// pass through the output device, which takes `outputLatencySeconds`. So what's heard
/// now is what was rendered that long ago. Keeping a short history, rather than reading
/// the player's position directly, keeps this right across pauses: after a pause, the
/// audio already on its way is still heard, and only then does the clock stop.
public struct PlaybackClock: Sendable {
    public var outputLatencySeconds: Double

    private struct RenderedPositionSample: Sendable {
        var hostSeconds: Double
        var renderedContentSeconds: Double
        var isAdvancing: Bool
    }

    private var samples: [RenderedPositionSample] = []

    // History older than the output delay plus this margin can never be asked for again.
    private let historyMarginSeconds = 2.0

    public init(outputLatencySeconds: Double) {
        self.outputLatencySeconds = outputLatencySeconds
    }

    public var recordedSampleCount: Int { samples.count }

    /// Call with each position the audio engine reports, in time order.
    /// `isAdvancing` is false while playback is paused.
    public mutating func recordRenderedPosition(hostSeconds: Double, renderedContentSeconds: Double, isAdvancing: Bool) {
        if let lastSample = samples.last, hostSeconds <= lastSample.hostSeconds { return }
        samples.append(RenderedPositionSample(hostSeconds: hostSeconds, renderedContentSeconds: renderedContentSeconds, isAdvancing: isAdvancing))
        dropSamplesNoLongerNeeded(newestHostSeconds: hostSeconds)
    }

    private mutating func dropSamplesNoLongerNeeded(newestHostSeconds: Double) {
        let oldestHostSecondsStillNeeded = newestHostSeconds - outputLatencySeconds - historyMarginSeconds
        // Removing in batches keeps this cheap when it's called every few milliseconds.
        guard samples.count > 64, let firstSample = samples.first, firstSample.hostSeconds < oldestHostSecondsStillNeeded - 1 else { return }
        let firstIndexToKeep = max(0, (samples.firstIndex { $0.hostSeconds >= oldestHostSecondsStillNeeded } ?? samples.count) - 1)
        samples.removeFirst(firstIndexToKeep)
    }

    public func heardContentSeconds(atHostSeconds hostSeconds: Double) -> Double {
        let renderedAtHostSeconds = hostSeconds - outputLatencySeconds
        guard let indexAtOrBefore = lastSampleIndex(atOrBefore: renderedAtHostSeconds) else { return 0 }
        let sampleBefore = samples[indexAtOrBefore]

        if indexAtOrBefore + 1 < samples.count {
            let sampleAfter = samples[indexAtOrBefore + 1]
            let fractionOfTheWay =
                (renderedAtHostSeconds - sampleBefore.hostSeconds) / (sampleAfter.hostSeconds - sampleBefore.hostSeconds)
            return sampleBefore.renderedContentSeconds
                + fractionOfTheWay * (sampleAfter.renderedContentSeconds - sampleBefore.renderedContentSeconds)
        }

        // Past the newest report: assume real-time playback only if it was playing.
        guard sampleBefore.isAdvancing else { return sampleBefore.renderedContentSeconds }
        return sampleBefore.renderedContentSeconds + (renderedAtHostSeconds - sampleBefore.hostSeconds)
    }

    private func lastSampleIndex(atOrBefore hostSeconds: Double) -> Int? {
        var lowIndex = 0
        var highIndex = samples.count - 1
        var foundIndex: Int?
        while lowIndex <= highIndex {
            let middleIndex = (lowIndex + highIndex) / 2
            if samples[middleIndex].hostSeconds <= hostSeconds {
                foundIndex = middleIndex
                lowIndex = middleIndex + 1
            } else {
                highIndex = middleIndex - 1
            }
        }
        return foundIndex
    }
}

/// Decides when to pause and resume playback, so that a gap in the network stream pauses
/// the player instead of letting it run on through silence. A player that keeps running on
/// an empty queue keeps counting time, and the marks would drift ahead of the voice.
public struct PlaybackStallGuard: Sendable {
    public enum Decision: Sendable, Equatable {
        case keepWaiting
        case startPlaying
        case keepPlaying
        case pauseForMoreAudio
    }

    /// Small enough to keep the first audio fast.
    public var startWhenBufferedSeconds = 0.15
    /// Pausing takes up to one check interval, so this leaves room before the queue is empty.
    public var pauseWhenBufferedBelowSeconds = 0.06
    /// Larger than the start buffer, so a slow stream doesn't stutter on and off.
    public var resumeWhenBufferedSeconds = 0.30

    public private(set) var isPlaying = false
    public private(set) var stallCount = 0
    private var hasStartedBefore = false

    public init() {}

    public mutating func decide(bufferedAheadSeconds: Double, streamHasEnded: Bool) -> Decision {
        if isPlaying {
            if !streamHasEnded && bufferedAheadSeconds < pauseWhenBufferedBelowSeconds {
                isPlaying = false
                stallCount += 1
                return .pauseForMoreAudio
            }
            return .keepPlaying
        }

        let bufferNeededToPlay = hasStartedBefore ? resumeWhenBufferedSeconds : startWhenBufferedSeconds
        let enoughToPlay =
            bufferedAheadSeconds >= bufferNeededToPlay
            || (streamHasEnded && bufferedAheadSeconds > 0)
        guard enoughToPlay else { return .keepWaiting }
        isPlaying = true
        hasStartedBefore = true
        return .startPlaying
    }
}

/// Hands out each word once, when it's due to be marked.
public struct WordCueScheduler: Sendable {
    /// Marks appear this long before their word. 80 ms is a starting guess, tuned by ear.
    public var leadSeconds: Double
    private var nextWordIndex = 0

    // Times are in floating-point seconds, so an exact tie can land a hair short.
    private let comparisonToleranceSeconds = 1e-9

    public init(leadSeconds: Double) {
        self.leadSeconds = leadSeconds
    }

    public mutating func takeDueWords(from words: [SpokenWord], heardContentSeconds: Double) -> [SpokenWord] {
        var dueWords: [SpokenWord] = []
        while nextWordIndex < words.count,
              heardContentSeconds + leadSeconds + comparisonToleranceSeconds >= words[nextWordIndex].startSeconds {
            dueWords.append(words[nextWordIndex])
            nextWordIndex += 1
        }
        return dueWords
    }
}
