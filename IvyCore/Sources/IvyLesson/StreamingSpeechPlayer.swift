import AVFoundation
import CoreAudio
import Foundation
import IvyCore

func currentHostSeconds() -> Double {
    AVAudioTime.seconds(forHostTime: mach_absolute_time())
}

/// Plays 24 kHz mono speech as it streams in, and keeps a `PlaybackClock` of what's heard.
///
/// This is the shape the app's player will take: audio is queued as it arrives, the stall
/// guard pauses playback when the queue runs low, and the clock is fed from the engine's
/// own render timestamps rather than from wall time.
final class StreamingSpeechPlayer {
    static let sampleRate = 24_000.0

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private(set) var clock = PlaybackClock(outputLatencySeconds: 0)
    private(set) var stallGuard = PlaybackStallGuard()
    private(set) var scheduledFrameCount: Int64 = 0
    private(set) var streamHasEnded = false
    private var lastRenderedContentSeconds = 0.0

    // Evidence for the questions D1 has to answer.
    private(set) var reportedOutputLatencySeconds = 0.0
    private(set) var engineReportedOutputLatencySeconds = 0.0
    private(set) var outputDeviceName = AudioDevices.defaultOutputDeviceName() + " (system default)"
    private(set) var timesPlayerRanDry = 0
    private(set) var largestPositionJumpAcrossAPauseSeconds = 0.0
    private(set) var pauseCount = 0
    private var renderedSecondsWhenPaused: Double?
    private var hostSecondsWhenResumed: Double?
    private var playerIsRunningDry = false

    init(outputDevice: AudioDevice?) throws {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: speechFormat)
        if let outputDevice {
            try audioEngine.outputNode.auAudioUnit.setDeviceID(outputDevice.deviceID)
            outputDeviceName = outputDevice.name
            outputDeviceID = outputDevice.deviceID
        }
        audioEngine.prepare()
        try audioEngine.start()
        engineReportedOutputLatencySeconds = audioEngine.outputNode.presentationLatency
        if let playingDeviceID = outputDevice?.deviceID ?? AudioDevices.defaultOutputDeviceID() {
            reportedOutputLatencySeconds = AudioDevices.latencySeconds(of: playingDeviceID, isInput: false)
        }
        clock.outputLatencySeconds = reportedOutputLatencySeconds
    }

    private var outputDeviceID: AudioDeviceID?

    /// The device's own volume and mute, which this lab doesn't change.
    var outputDeviceVolumeDescription: String {
        guard let outputDeviceID else { return "system default device, not read" }
        var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var volume: Float32 = -1
        var isMuted: UInt32 = 0
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(outputDeviceID, &volumeAddress, 0, nil, &volumeSize, &volume) != noErr {
            volumeAddress.mElement = 1
            AudioObjectGetPropertyData(outputDeviceID, &volumeAddress, 0, nil, &volumeSize, &volume)
        }
        AudioObjectGetPropertyData(outputDeviceID, &muteAddress, 0, nil, &muteSize, &isMuted)
        return String(format: "volume %.2f%@", volume, isMuted != 0 ? ", muted" : "")
    }

    var scheduledContentSeconds: Double { Double(scheduledFrameCount) / Self.sampleRate }

    func enqueue(samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { sourceSamples in
            buffer.floatChannelData![0].update(from: sourceSamples.baseAddress!, count: samples.count)
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        scheduledFrameCount += Int64(samples.count)
    }

    /// ElevenLabs sends little-endian 16-bit PCM.
    func enqueue(pcm16Data: Data) {
        let sampleCount = pcm16Data.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        pcm16Data.withUnsafeBytes { rawBytes in
            for sampleIndex in 0..<sampleCount {
                let sampleValue = Int16(littleEndian: rawBytes.loadUnaligned(fromByteOffset: sampleIndex * 2, as: Int16.self))
                samples[sampleIndex] = Float(sampleValue) / 32768
            }
        }
        enqueue(samples: samples)
    }

    func markStreamEnded() {
        streamHasEnded = true
    }

    /// Call on every screen frame. Records where playback is, pauses or resumes it, and
    /// returns how far into the speech the listener will be when `displayHostSeconds` arrives.
    func update(predictingHeardAtHostSeconds displayHostSeconds: Double) -> Double {
        recordRenderedPosition()

        let bufferedAheadSeconds = scheduledContentSeconds - lastRenderedContentSeconds
        switch stallGuard.decide(bufferedAheadSeconds: bufferedAheadSeconds, streamHasEnded: streamHasEnded) {
        case .startPlaying:
            hostSecondsWhenResumed = currentHostSeconds()
            playerNode.play()
        case .pauseForMoreAudio:
            playerNode.pause()
            pauseCount += 1
            renderedSecondsWhenPaused = lastRenderedContentSeconds
        case .keepPlaying, .keepWaiting:
            break
        }

        return min(clock.heardContentSeconds(atHostSeconds: displayHostSeconds), scheduledContentSeconds)
    }

    private func recordRenderedPosition() {
        let nowHostSeconds = currentHostSeconds()
        guard stallGuard.isPlaying,
              let renderTime = playerNode.lastRenderTime,
              renderTime.isHostTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else {
            clock.recordRenderedPosition(hostSeconds: nowHostSeconds, renderedContentSeconds: lastRenderedContentSeconds, isAdvancing: false)
            return
        }

        let renderedContentSeconds = Double(playerTime.sampleTime) / playerTime.sampleRate
        let renderHostSeconds = AVAudioTime.seconds(forHostTime: renderTime.hostTime)

        // D1's open question: does the player's position freeze while paused? If it counted
        // the pause, the first reading after resuming jumps by roughly the pause length.
        if let renderedSecondsWhenPaused, let hostSecondsWhenResumed {
            let expectedAdvanceSinceResume = max(0, renderHostSeconds - hostSecondsWhenResumed)
            let unexplainedJump = renderedContentSeconds - renderedSecondsWhenPaused - expectedAdvanceSinceResume
            largestPositionJumpAcrossAPauseSeconds = max(largestPositionJumpAcrossAPauseSeconds, unexplainedJump)
            self.renderedSecondsWhenPaused = nil
            self.hostSecondsWhenResumed = nil
        }

        // Rendering past the queued audio means the player ran on through silence.
        let isRunningDryNow = !streamHasEnded && renderedContentSeconds > scheduledContentSeconds + 0.005
        if isRunningDryNow && !playerIsRunningDry { timesPlayerRanDry += 1 }
        playerIsRunningDry = isRunningDryNow

        lastRenderedContentSeconds = min(renderedContentSeconds, scheduledContentSeconds)
        clock.recordRenderedPosition(hostSeconds: renderHostSeconds, renderedContentSeconds: lastRenderedContentSeconds, isAdvancing: true)
    }

    var hasFinishedPlaying: Bool {
        streamHasEnded && lastRenderedContentSeconds >= scheduledContentSeconds - 0.001
    }

    func stop() {
        playerNode.stop()
        audioEngine.stop()
    }
}
