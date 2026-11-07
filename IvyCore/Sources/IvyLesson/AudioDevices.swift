import CoreAudio
import Foundation

/// Finds audio devices by kind, so a test can use the built-in speakers or a Bluetooth
/// device without changing the Mac's default output.
public struct AudioDevice {
    public let deviceID: AudioDeviceID
    public let name: String
    public let isBuiltIn: Bool
    public let isBluetooth: Bool
    public let outputChannelCount: Int
    public let inputChannelCount: Int
}

public enum AudioDevices {
    public static func allDevices() -> [AudioDevice] {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize) == noErr else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        return deviceIDs.map { deviceID in
            let transportType = readUInt32(deviceID, selector: kAudioDevicePropertyTransportType)
            return AudioDevice(
                deviceID: deviceID,
                name: readName(deviceID),
                isBuiltIn: transportType == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE,
                outputChannelCount: channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput),
                inputChannelCount: channelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
            )
        }
    }

    /// "speakers" and "bluetooth" pick a device by kind. Anything else means the system default.
    public static func outputDevice(named choice: String) -> AudioDevice? {
        let outputDevices = allDevices().filter { $0.outputChannelCount > 0 }
        switch choice {
        case "speakers": return outputDevices.first { $0.isBuiltIn }
        case "bluetooth": return outputDevices.first { $0.isBluetooth }
        default: return nil
        }
    }

    public static func defaultOutputDeviceName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr else { return "unknown" }
        return readName(deviceID)
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr else { return nil }
        return deviceID
    }

    /// How long a sample takes to get from the app to the speaker, or from the mic to the app,
    /// added up from what the device itself reports: its own delay, its safety margin, the
    /// I/O buffer, and the stream's delay. AVAudioEngine's presentationLatency gave 1 ms for
    /// a device that wasn't the system default, so it can't be relied on here.
    public static func latencySeconds(of deviceID: AudioDeviceID, isInput: Bool) -> Double {
        let scope = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        func readFrames(_ selector: AudioObjectPropertySelector, _ objectID: AudioObjectID) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
            return value
        }
        var sampleRateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceSampleRate: Float64 = 0
        var sampleRateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &sampleRateAddress, 0, nil, &sampleRateSize, &deviceSampleRate)
        guard deviceSampleRate > 0 else { return 0 }

        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        var firstStreamLatencyFrames: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streamIDs = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &streamsSize, &streamIDs)
            if let firstStreamID = streamIDs.first {
                var streamLatencyAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var latencySize = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(firstStreamID, &streamLatencyAddress, 0, nil, &latencySize, &firstStreamLatencyFrames)
            }
        }

        let totalFrames =
            readFrames(kAudioDevicePropertyLatency, deviceID)
            + readFrames(kAudioDevicePropertySafetyOffset, deviceID)
            + readFrames(kAudioDevicePropertyBufferFrameSize, deviceID)
            + firstStreamLatencyFrames
        return Double(totalFrames) / deviceSampleRate
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// The mic to record from. Opening a Bluetooth headset's mic switches the headset from its
    /// music mode into a lower-quality call mode, which also rebuilds the audio devices under
    /// every app that's playing. So when the default mic is a Bluetooth headset and the Mac has
    /// its own mic, this picks the Mac's mic, and the headset keeps playing in full quality.
    /// Any other mic the person chose, like a USB or wired one, is used as it is.
    public static func microphoneThatKeepsHeadsetsInMusicMode() -> AudioDeviceID? {
        guard let defaultInputDeviceID = defaultInputDeviceID() else { return nil }
        let defaultInputIsBluetooth = allDevices().first { $0.deviceID == defaultInputDeviceID }?.isBluetooth ?? false
        if defaultInputIsBluetooth, let builtInMicrophone = builtInMicrophone() {
            return builtInMicrophone.deviceID
        }
        return defaultInputDeviceID
    }

    public static func deviceStillExists(_ deviceID: AudioDeviceID) -> Bool {
        allDevices().contains { $0.deviceID == deviceID }
    }

    public static func builtInMicrophone() -> AudioDevice? {
        allDevices().first { $0.isBuiltIn && $0.inputChannelCount > 0 }
    }

    private static func readUInt32(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return value
    }

    private static func readName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name) == noErr, let name else { return "unknown" }
        return name.takeRetainedValue() as String
    }

    private static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }
        let rawBufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawBufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBufferList) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawBufferList.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
