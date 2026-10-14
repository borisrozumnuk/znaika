import AVFoundation
import CoreAudio

/// Захват микрофона напрямую через Core Audio (IOProc на выбранном устройстве ввода).
///
/// AVAudioEngine не подходит: при первом обращении к inputNode он открывает
/// микрофон по умолчанию, и если это Bluetooth-наушники, они уходят
/// в гарнитурный режим ещё до того, как устройство удастся сменить.
final class MicCapture {
    private var recorder: DeviceRecorder?
    private(set) var device: AudioDevices.Device?

    /// Запрашивает доступ к микрофону, не блокируя главный поток.
    static func requestPermission(_ completion: @escaping (Result<Void, CaptureError>) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(.success(()))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted ? .success(()) : .failure(CaptureError("доступ к микрофону не выдан")))
                }
            }
        default:
            completion(.failure(CaptureError(
                "доступ к микрофону запрещён: Системные настройки → Конфиденциальность и безопасность → Микрофон"
            )))
        }
    }

    func start(url: URL, device: AudioDevices.Device, startHostTime: UInt64) throws -> AudioSink {
        // Формат первого входного потока: его и берёт DeviceRecorder (.first).
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &format),
            "\(device.name): kAudioDevicePropertyStreamFormat"
        )

        let recorder = try DeviceRecorder(label: "mic", deviceID: device.id, format: format, pick: .first, startHostTime: startHostTime, url: url)
        self.recorder = recorder
        self.device = device
        try recorder.start()
        return recorder.sink
    }

    func setPaused(_ paused: Bool) { recorder?.setPaused(paused) }

    func stop(endHostTime: UInt64) {
        recorder?.stop(endHostTime: endHostTime)
        recorder = nil
    }
}
