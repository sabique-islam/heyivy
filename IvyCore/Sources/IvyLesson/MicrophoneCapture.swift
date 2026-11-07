import AVFoundation
import CoreAudio
import Foundation

/// Records from the microphone and hands each buffer to a callback, on any mic and through
/// device changes. The app's push-to-talk and the voice lab both use it, so what the lab
/// tests is what the app runs.
///
/// Two things make this harder than starting an engine:
///
/// - Opening a Bluetooth headset's mic switches the headset from music mode into call mode,
///   which rebuilds audio devices under every app. So the Mac's own mic is used instead when
///   there is one. See `AudioDevices.microphoneThatKeepsHeadsetsInMusicMode`.
/// - Choosing a mic, or a mic being plugged in or removed, posts a configuration change.
///   When it stops the engine, recording restarts on the current mic. When the engine is
///   still running, as after choosing the mic just before starting, it's left alone,
///   because restarting a working engine is what loses audio.
public final class MicrophoneCapture {
    // Written on the audio thread and read on the main thread, so they're behind a lock.
    private let measurementLock = NSLock()
    private var capturedBufferCountStorage = 0
    private var capturedSecondsStorage = 0.0
    private var peakLevelStorage: Float = 0
    public var capturedBufferCount: Int { measurementLock.withLock { capturedBufferCountStorage } }
    /// macOS treats the requested buffer size as a hint, so this, not the buffer count, says
    /// how much audio arrived.
    public var capturedSeconds: Double { measurementLock.withLock { capturedSecondsStorage } }
    public var peakLevel: Float { measurementLock.withLock { peakLevelStorage } }
    public private(set) var restartsAfterDeviceChange = 0
    public private(set) var deviceChangesIgnoredWhileRunning = 0
    public private(set) var microphoneName = "none"

    private let audioEngine = AVAudioEngine()
    private var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var deviceChangeObserver: NSObjectProtocol?
    private var isCapturing = false

    public init() {
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleDeviceChange()
        }
    }

    deinit {
        if let deviceChangeObserver { NotificationCenter.default.removeObserver(deviceChangeObserver) }
    }

    /// `onAudioBuffer` runs on an audio thread, once per buffer.
    public func start(onAudioBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.onAudioBuffer = onAudioBuffer
        measurementLock.withLock {
            capturedBufferCountStorage = 0
            capturedSecondsStorage = 0
            peakLevelStorage = 0
        }
        restartsAfterDeviceChange = 0
        deviceChangesIgnoredWhileRunning = 0
        isCapturing = true
        try startEngineOnTheChosenMicrophone()
    }

    public func stop() {
        isCapturing = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        onAudioBuffer = nil
    }

    private func startEngineOnTheChosenMicrophone() throws {
        audioEngine.stop()
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        if let chosenMicrophoneID = AudioDevices.microphoneThatKeepsHeadsetsInMusicMode(),
           inputNode.auAudioUnit.deviceID != chosenMicrophoneID {
            try inputNode.auAudioUnit.setDeviceID(chosenMicrophoneID)
        }
        let currentDeviceID = inputNode.auAudioUnit.deviceID
        microphoneName = AudioDevices.allDevices().first { $0.deviceID == currentDeviceID }?.name ?? "unknown"

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw MicrophoneCaptureError(message: "The microphone isn't ready (no channels).")
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            var bufferPeakLevel: Float = 0
            if let channelSamples = buffer.floatChannelData?[0] {
                for sampleIndex in 0..<Int(buffer.frameLength) {
                    bufferPeakLevel = max(bufferPeakLevel, abs(channelSamples[sampleIndex]))
                }
            }
            self.measurementLock.withLock {
                self.capturedBufferCountStorage += 1
                self.capturedSecondsStorage += Double(buffer.frameLength) / buffer.format.sampleRate
                self.peakLevelStorage = max(self.peakLevelStorage, bufferPeakLevel)
            }
            self.onAudioBuffer?(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func handleDeviceChange() {
        guard isCapturing else { return }
        if audioEngine.isRunning {
            deviceChangesIgnoredWhileRunning += 1
            return
        }
        restartsAfterDeviceChange += 1
        do {
            try startEngineOnTheChosenMicrophone()
        } catch {
            print("⚠️ MicrophoneCapture: couldn't restart after a device change: \(error)")
        }
    }
}

public struct MicrophoneCaptureError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
