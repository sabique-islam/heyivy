import AVFoundation
import CoreAudio
import Foundation
import IvyCore

/// Measures sync without anyone watching: short clicks are played as if they were words,
/// the screen flashes when the clock says each click is heard, and the microphone records
/// when each click actually came out of the speaker. The difference is the sync error.
///
/// The stream is fed in pieces with two forced gaps, so it also checks the clock across stalls.
enum ClickTrack {
    static let clickCount = 18
    static let clickDurationSeconds = 0.008
    static let clickFrequencyHertz = 2_000.0

    /// Uneven gaps, so a click can't be matched to its neighbour by accident.
    static let clickContentTimes: [Double] = (0..<clickCount).map { clickIndex in
        0.6 + Double(clickIndex) * 0.55 + Double(clickIndex % 3) * 0.07
    }

    static var clickWords: [SpokenWord] {
        clickContentTimes.enumerated().map { clickIndex, startSeconds in
            SpokenWord(text: "click\(clickIndex)", startSeconds: startSeconds, endSeconds: startSeconds + clickDurationSeconds, wordIndex: clickIndex)
        }
    }

    static func makeSamples() -> [Float] {
        let sampleRate = StreamingSpeechPlayer.sampleRate
        let totalSeconds = (clickContentTimes.last ?? 0) + 0.8
        var samples = [Float](repeating: 0, count: Int(totalSeconds * sampleRate))
        let clickSampleCount = Int(clickDurationSeconds * sampleRate)
        for clickStartSeconds in clickContentTimes {
            let firstSampleIndex = Int(clickStartSeconds * sampleRate)
            for offset in 0..<clickSampleCount {
                let smoothingWindow = 0.5 - 0.5 * cos(2 * Double.pi * Double(offset) / Double(clickSampleCount))
                let tone = sin(2 * Double.pi * clickFrequencyHertz * Double(offset) / sampleRate)
                samples[firstSampleIndex + offset] = Float(0.9 * smoothingWindow * tone)
            }
        }
        return samples
    }
}

/// Feeds audio to the player a little faster than real time, like a network stream, with
/// two gaps long enough to empty the queue.
final class SimulatedNetworkFeed {
    private let allSamples: [Float]
    private var samplesDelivered = 0
    private let startHostSeconds = currentHostSeconds()
    private var feedingIsBlockedUntilHostSeconds = 0.0
    private var remainingForcedGaps: [(afterContentSeconds: Double, gapSeconds: Double)]
    private(set) var forcedGapContentTimes: [Double] = []

    init(samples: [Float], forcedGaps: [(afterContentSeconds: Double, gapSeconds: Double)]) {
        allSamples = samples
        remainingForcedGaps = forcedGaps
    }

    var hasDeliveredEverything: Bool { samplesDelivered >= allSamples.count }

    func deliverWhatHasArrived(to speechPlayer: StreamingSpeechPlayer) {
        let nowHostSeconds = currentHostSeconds()
        guard nowHostSeconds >= feedingIsBlockedUntilHostSeconds, !hasDeliveredEverything else { return }

        let sampleRate = StreamingSpeechPlayer.sampleRate
        let secondsSinceStart = nowHostSeconds - startHostSeconds
        let contentSecondsArrivedSoFar = 0.25 + secondsSinceStart * 1.05
        let pieceSampleCount = Int(0.1 * sampleRate)

        while samplesDelivered < allSamples.count, Double(samplesDelivered) / sampleRate < contentSecondsArrivedSoFar {
            let deliveredContentSeconds = Double(samplesDelivered) / sampleRate
            if let nextGap = remainingForcedGaps.first, deliveredContentSeconds >= nextGap.afterContentSeconds {
                remainingForcedGaps.removeFirst()
                forcedGapContentTimes.append(deliveredContentSeconds)
                feedingIsBlockedUntilHostSeconds = nowHostSeconds + nextGap.gapSeconds
                return
            }
            let pieceEnd = min(allSamples.count, samplesDelivered + pieceSampleCount)
            speechPlayer.enqueue(samples: Array(allSamples[samplesDelivered..<pieceEnd]))
            samplesDelivered = pieceEnd
        }
        if hasDeliveredEverything { speechPlayer.markStreamEnded() }
    }
}

/// Records the built-in microphone and finds when each click arrived.
final class MicrophoneClickRecorder {
    private let audioEngine = AVAudioEngine()
    private let recordingQueue = DispatchQueue(label: "microphone-recording")
    private var recordedBuffers: [(firstSampleHostSeconds: Double, samples: [Float])] = []
    private(set) var sampleRate = 48_000.0
    private(set) var reportedInputLatencySeconds = 0.0
    private(set) var inputDeviceName = "system default"
    private var recordingDeviceID: AudioDeviceID?

    init(inputDevice: AudioDevice?) throws {
        if let inputDevice {
            try audioEngine.inputNode.auAudioUnit.setDeviceID(inputDevice.deviceID)
            inputDeviceName = inputDevice.name
            recordingDeviceID = inputDevice.deviceID
        }
    }

    func start() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        sampleRate = inputFormat.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, bufferTime in
            guard let self, bufferTime.isHostTimeValid, let channelSamples = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channelSamples, count: Int(buffer.frameLength)))
            let firstSampleHostSeconds = AVAudioTime.seconds(forHostTime: bufferTime.hostTime)
            self.recordingQueue.async { self.recordedBuffers.append((firstSampleHostSeconds, samples)) }
        }
        audioEngine.prepare()
        try audioEngine.start()
        if let recordingDeviceID = recordingDeviceID {
            reportedInputLatencySeconds = AudioDevices.latencySeconds(of: recordingDeviceID, isInput: true)
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    /// Kept so a failed run can be inspected. It holds only the test clicks and room sound.
    func writeRecording(toPath recordingPath: String) {
        let allSamples = recordingQueue.sync { recordedBuffers.flatMap(\.samples) }
        guard let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let recordingBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: AVAudioFrameCount(allSamples.count)) else { return }
        recordingBuffer.frameLength = AVAudioFrameCount(allSamples.count)
        allSamples.withUnsafeBufferPointer { recordingBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: allSamples.count) }
        try? FileManager.default.removeItem(atPath: recordingPath)
        if let recordingFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: recordingPath), settings: recordingFormat.settings) {
            try? recordingFile.write(from: recordingBuffer)
        }
    }

    var peakLevel: Float {
        recordingQueue.sync { recordedBuffers.flatMap(\.samples).map(abs).max() ?? 0 }
    }

    /// The host time each click reached the microphone. A click is the first loud sample after
    /// a quiet stretch. The difference between neighbouring samples is used rather than the
    /// level, which ignores low rumble and keeps the 2 kHz click.
    func clickArrivalHostTimes() -> [Double] {
        let buffers = recordingQueue.sync { recordedBuffers }
        var highPassedLevels: [(hostSeconds: Double, level: Float)] = []
        var previousSample: Float = 0
        for buffer in buffers {
            for (sampleIndex, sample) in buffer.samples.enumerated() {
                let sampleHostSeconds = buffer.firstSampleHostSeconds + Double(sampleIndex) / sampleRate - reportedInputLatencySeconds
                highPassedLevels.append((sampleHostSeconds, abs(sample - previousSample)))
                previousSample = sample
            }
        }
        guard let loudestLevel = highPassedLevels.map(\.level).max(), loudestLevel > 0 else { return [] }

        let clickThreshold = loudestLevel * 0.3
        let quietSecondsBeforeAClick = 0.25
        var arrivalHostTimes: [Double] = []
        var lastLoudHostSeconds = -Double.infinity
        for (sampleHostSeconds, level) in highPassedLevels where level >= clickThreshold {
            if sampleHostSeconds - lastLoudHostSeconds >= quietSecondsBeforeAClick {
                arrivalHostTimes.append(sampleHostSeconds)
            }
            lastLoudHostSeconds = sampleHostSeconds
        }
        return arrivalHostTimes
    }
}
