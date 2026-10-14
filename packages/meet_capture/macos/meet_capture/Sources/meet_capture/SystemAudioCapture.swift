import CoreAudio
import Foundation

/// Захват системного звука через Core Audio Process Tap (macOS 14.2+).
/// Схема: tap на весь вывод системы → приватное aggregate-устройство
/// (устройство вывода + tap) → DeviceRecorder.
///
/// Устройство вывода нужно как главное под-устройство: оно задаёт часы IO-цикла.
/// Aggregate из одного tap на macOS 26 иногда не запускается: AudioDeviceStart
/// не возвращается, держит блокировку HAL, и вслед за ним виснет запуск
/// микрофона — а с ним и весь coreaudiod до перезапуска. Так же делают пример
/// Apple «Capturing system audio with Core Audio taps» и AudioCap.
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var recorder: DeviceRecorder?

    func start(url: URL, startHostTime: UInt64) throws -> AudioSink {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "capture-proto tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "kAudioTapPropertyFormat")

        let outputUID = try defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "capture-proto aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            "AudioHardwareCreateAggregateDevice"
        )

        let recorder = try DeviceRecorder(
            label: "system", deviceID: aggregateID, format: format, pick: .last, startHostTime: startHostTime, url: url
        )
        self.recorder = recorder
        try recorder.start()
        return recorder.sink
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
            "kAudioHardwarePropertyDefaultOutputDevice"
        )
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "kAudioDevicePropertyDeviceUID")
        guard let uid else { throw CaptureError("у устройства вывода нет UID") }
        return uid.takeRetainedValue() as String
    }

    func setPaused(_ paused: Bool) { recorder?.setPaused(paused) }

    func stop(endHostTime: UInt64) {
        recorder?.stop(endHostTime: endHostTime)
        recorder = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
