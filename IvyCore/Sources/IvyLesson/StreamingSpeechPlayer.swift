import AVFoundation
import CoreAudio
import Foundation
import IvyCore

public func currentHostSeconds() -> Double {
    AVAudioTime.seconds(forHostTime: mach_absolute_time())
}

/// Plays 24 kHz mono speech as it streams in, and keeps a `PlaybackClock` of what's heard.
///
/// This is the shape the app's player will take: audio is queued as it arrives, the stall
/// guard pauses playback when the queue runs low, and the clock is fed from the engine's
/// own render timestamps rather than from wall time.
public final class StreamingSpeechPlayer {
    public static let sampleRate = 24_000.0

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    public private(set) var clock = PlaybackClock(outputLatencySeconds: 0)
    public private(set) var stallGuard = PlaybackStallGuard()
    public private(set) var scheduledFrameCount: Int64 = 0
    public private(set) var streamHasEnded = false
    private var lastRenderedContentSeconds = 0.0

    // Kept so speech can carry on after the output device changes, which drops whatever the
    // player had queued. A long answer is a few megabytes at most.
    private var allReceivedSamples: [Float] = []
    /// Where the player's current run started in the speech. The player counts from zero
    /// each time it restarts, so this is added to its position.
    private var currentRunStartFrame: Int64 = 0
    private var outputDeviceChangeObserver: NSObjectProtocol?
    public private(set) var outputDeviceChangesRecovered = 0
    /// Called if playback couldn't continue after the output device changed.
    public var onPlaybackFailed: (() -> Void)?

    // Evidence for the questions D1 has to answer.
    public private(set) var reportedOutputLatencySeconds = 0.0
    public private(set) var engineReportedOutputLatencySeconds = 0.0
    public private(set) var outputDeviceName = AudioDevices.defaultOutputDeviceName() + " (system default)"
    public private(set) var timesPlayerRanDry = 0
    public private(set) var largestPositionJumpAcrossAPauseSeconds = 0.0
    public private(set) var pauseCount = 0
    private var renderedSecondsWhenPaused: Double?
    private var hostSecondsWhenResumed: Double?
    private var playerIsRunningDry = false

    public init(outputDevice: AudioDevice?) throws {
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

        // Plugging in headphones, a headset changing mode, or a device disconnecting all stop
        // the engine. Without this, speech would go silent and marks would stop.
        outputDeviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.continueOnTheNewOutputDevice()
        }
    }

    deinit {
        if let outputDeviceChangeObserver { NotificationCenter.default.removeObserver(outputDeviceChangeObserver) }
    }

    /// Restarts on whatever device is now in use, from the point the listener had heard, so
    /// nothing in the old device's pipeline is lost. Also used by the voice lab to test this.
    public func continueOnTheNewOutputDevice() {
        let resumeContentSeconds = max(0, min(clock.heardContentSeconds(atHostSeconds: currentHostSeconds()), scheduledContentSeconds))
        let resumeFrame = Int64(resumeContentSeconds * Self.sampleRate)

        playerNode.stop()
        audioEngine.stop()
        // A device chosen by name may be the one that just disappeared.
        if let outputDeviceID, AudioDevices.deviceStillExists(outputDeviceID) {
            try? audioEngine.outputNode.auAudioUnit.setDeviceID(outputDeviceID)
        }
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: speechFormat)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onPlaybackFailed?()
            return
        }

        // The new device has its own delay, so the clock starts afresh from the resume point.
        let playingDeviceID = (outputDeviceID.flatMap { AudioDevices.deviceStillExists($0) ? $0 : nil }) ?? AudioDevices.defaultOutputDeviceID()
        if let playingDeviceID {
            reportedOutputLatencySeconds = AudioDevices.latencySeconds(of: playingDeviceID, isInput: false)
        }
        clock = PlaybackClock(outputLatencySeconds: reportedOutputLatencySeconds)
        clock.recordRenderedPosition(hostSeconds: currentHostSeconds(), renderedContentSeconds: resumeContentSeconds, isAdvancing: false)
        lastRenderedContentSeconds = resumeContentSeconds
        currentRunStartFrame = resumeFrame

        if resumeFrame < Int64(allReceivedSamples.count) {
            scheduleOnPlayer(Array(allReceivedSamples[Int(resumeFrame)...]))
        }
        if stallGuard.isPlaying { playerNode.play() }
        outputDeviceChangesRecovered += 1
    }

    private var outputDeviceID: AudioDeviceID?

    /// The device's own volume and mute, which this lab doesn't change.
    public var outputDeviceVolumeDescription: String {
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

    public var scheduledContentSeconds: Double { Double(scheduledFrameCount) / Self.sampleRate }

    public func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        allReceivedSamples.append(contentsOf: samples)
        scheduleOnPlayer(samples)
        scheduledFrameCount += Int64(samples.count)
    }

    private func scheduleOnPlayer(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { sourceSamples in
            buffer.floatChannelData![0].update(from: sourceSamples.baseAddress!, count: samples.count)
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// ElevenLabs sends little-endian 16-bit PCM.
    public func enqueue(pcm16Data: Data) {
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

    public func markStreamEnded() {
        streamHasEnded = true
    }

    /// Call on every screen frame. Records where playback is, pauses or resumes it, and
    /// returns how far into the speech the listener will be when `displayHostSeconds` arrives.
    public func update(predictingHeardAtHostSeconds displayHostSeconds: Double) -> Double {
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

        let renderedContentSeconds = Double(currentRunStartFrame) / Self.sampleRate + Double(playerTime.sampleTime) / playerTime.sampleRate
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

    public var hasFinishedPlaying: Bool {
        streamHasEnded && lastRenderedContentSeconds >= scheduledContentSeconds - 0.001
    }

    public func stop() {
        if let outputDeviceChangeObserver {
            NotificationCenter.default.removeObserver(outputDeviceChangeObserver)
            self.outputDeviceChangeObserver = nil
        }
        playerNode.stop()
        audioEngine.stop()
    }
}
