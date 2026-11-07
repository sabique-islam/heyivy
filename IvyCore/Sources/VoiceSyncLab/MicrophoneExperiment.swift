import AVFoundation
import CoreAudio
import Foundation
import IvyLesson

/// Compares ways of switching to the Mac's mic while a Bluetooth headset is the default, by
/// counting the buffers each delivers in 4 seconds. About 187 is normal at 48 kHz.
enum MicrophoneExperiment {
    enum Strategy: String, CaseIterable {
        case ignoreChangeWhileRunning
        case alwaysRestartOnChange
        case freshEngineAndWaitForChange
    }

    static func runAll(completion: @escaping ([[String: Any]]) -> Void) {
        var reports: [[String: Any]] = []
        func runNext(_ remaining: [Strategy]) {
            guard let strategy = remaining.first else { return completion(reports) }
            run(strategy) { report in
                reports.append(report)
                // Let the headset settle between runs.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { runNext(Array(remaining.dropFirst())) }
            }
        }
        runNext(Strategy.allCases)
    }

    private static func run(_ strategy: Strategy, completion: @escaping ([String: Any]) -> Void) {
        let audioEngine = AVAudioEngine()
        let bufferLock = NSLock()
        var bufferCount = 0
        var framesCaptured = 0
        var bufferSampleRates = Set<Double>()
        var tapFormatSampleRates: [Double] = []
        var changesSeen = 0
        var restarts = 0
        var bufferCountAtFirstChange: Int?

        func startEngine() {
            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0)
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0 else { return }
            tapFormatSampleRates.append(format.sampleRate)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                bufferLock.withLock {
                    bufferCount += 1
                    framesCaptured += Int(buffer.frameLength)
                    bufferSampleRates.insert(buffer.format.sampleRate)
                }
            }
            audioEngine.prepare()
            try? audioEngine.start()
        }

        var waitingForChangeBeforeStarting = strategy == .freshEngineAndWaitForChange
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { _ in
            changesSeen += 1
            if bufferCountAtFirstChange == nil { bufferCountAtFirstChange = bufferLock.withLock { bufferCount } }
            switch strategy {
            case .ignoreChangeWhileRunning:
                if !audioEngine.isRunning { restarts += 1; startEngine() }
            case .alwaysRestartOnChange:
                restarts += 1
                audioEngine.stop()
                startEngine()
            case .freshEngineAndWaitForChange:
                if waitingForChangeBeforeStarting {
                    waitingForChangeBeforeStarting = false
                    startEngine()
                } else {
                    restarts += 1
                    audioEngine.stop()
                    startEngine()
                }
            }
        }

        if let microphoneID = AudioDevices.microphoneThatKeepsHeadsetsInMusicMode(), audioEngine.inputNode.auAudioUnit.deviceID != microphoneID {
            try? audioEngine.inputNode.auAudioUnit.setDeviceID(microphoneID)
        } else {
            waitingForChangeBeforeStarting = false
        }
        if !waitingForChangeBeforeStarting { startEngine() }
        // If no change ever arrives, start anyway rather than record nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if waitingForChangeBeforeStarting { waitingForChangeBeforeStarting = false; startEngine() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            NotificationCenter.default.removeObserver(observer)
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            completion([
                "strategy": strategy.rawValue,
                "buffersIn4Seconds": bufferLock.withLock { bufferCount },
                "changeNotifications": changesSeen,
                "restarts": restarts,
                "buffersBeforeFirstChange": bufferCountAtFirstChange ?? -1,
                "framesCaptured": bufferLock.withLock { framesCaptured },
                "tapFormatSampleRates": tapFormatSampleRates,
                "bufferSampleRates": bufferLock.withLock { Array(bufferSampleRates) },
                "microphoneNominalSampleRate": microphoneNominalSampleRate(audioEngine.inputNode.auAudioUnit.deviceID),
            ])
        }
    }
}

private func microphoneNominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sampleRate: Float64 = 0
    var dataSize = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
    return sampleRate
}
