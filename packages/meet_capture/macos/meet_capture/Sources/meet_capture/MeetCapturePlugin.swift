import Cocoa
import FlutterMacOS

/// Канал `meet_capture`: start / stop / inputDevices.
/// Канал событий `meet_capture/levels`: уровни каналов в дБ 10 раз в секунду.
/// Канал событий `meet_capture/audio`: отсчёты 16 кГц моно по каналам 10 раз в секунду
/// (для расшифровки на лету; только если start вызван с streamAudio: true).
///
/// Системные устройства не переключаются: микрофон — вход, выбранный в системе,
/// или явно указанный по названию.
///
/// Запуск и остановка идут на отдельной очереди, а не на главном потоке:
/// AudioDeviceStart блокируется, пока coreaudiod не разрешит доступ к устройству
/// (например, ждёт решения TCC по микрофону). На главном потоке это вешает всё
/// приложение, и системный запрос доступа может так и не показаться.
public class MeetCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private let controlQueue = DispatchQueue(label: "meet_capture.control", qos: .userInitiated)
    /// Текущая запись; меняется только на главном потоке.
    fileprivate var session: CaptureSession?
    private var starting = false
    private var levelSink: FlutterEventSink?
    private var levelTimer: Timer?

    /// Сколько ждать запуска устройств, прежде чем сообщить о зависании.
    private static let startTimeout: TimeInterval = 10

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MeetCapturePlugin()
        let channel = FlutterMethodChannel(name: "meet_capture", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(instance, channel: channel)
        let levels = FlutterEventChannel(name: "meet_capture/levels", binaryMessenger: registrar.messenger)
        levels.setStreamHandler(instance)
        let audio = FlutterEventChannel(name: "meet_capture/audio", binaryMessenger: registrar.messenger)
        audio.setStreamHandler(AudioStreamHandler(plugin: instance))
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "inputDevices":
            let current = AudioDevices.defaultInput()?.id
            result(AudioDevices.inputs().map {
                ["name": $0.name, "isBluetooth": $0.isBluetooth, "isDefault": $0.id == current]
            })
        case "start":
            guard session == nil, !starting else {
                result(FlutterError(code: "busy", message: "запись уже идёт", details: nil))
                return
            }
            guard let outDir = args["outDir"] as? String else {
                result(FlutterError(code: "args", message: "нужен outDir", details: nil))
                return
            }
            let options = CaptureSession.Options(
                outDir: URL(fileURLWithPath: outDir),
                system: args["system"] as? Bool ?? true,
                mic: args["mic"] as? Bool ?? true,
                micDevice: args["micDevice"] as? String,
                streamAudio: args["streamAudio"] as? Bool ?? false
            )
            starting = true
            if options.mic {
                MicCapture.requestPermission { [weak self] permission in
                    switch permission {
                    case .success:
                        self?.start(options, result: result)
                    case .failure(let error):
                        self?.starting = false
                        result(FlutterError(code: "permission", message: error.description, details: nil))
                    }
                }
            } else {
                start(options, result: result)
            }
        case "stop":
            stop(result: result)
        case "pause", "resume":
            // Пауза — в обоих каналах сразу: они пропускают один и тот же отрезок.
            session?.setPaused(call.method == "pause")
            result(session != nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start(_ options: CaptureSession.Options, result: @escaping FlutterResult) {
        // Ответ во Flutter — ровно один раз: либо результат запуска, либо таймаут.
        var answered = false
        let answer: (Any?) -> Void = { value in
            guard !answered else { return }
            answered = true
            result(value)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            guard !answered else { return }
            self?.starting = false
            answer(FlutterError(
                code: "start_timeout",
                message: "Звуковое устройство не запустилось за \(Int(Self.startTimeout)) с. Скорее всего, macOS ждёт "
                    + "решения по доступу к микрофону или системному звуку: проверьте Системные настройки → "
                    + "Конфиденциальность и безопасность → Микрофон и «Запись экрана и системного звука».",
                details: nil
            ))
        }

        controlQueue.async { [weak self] in
            let outcome = Result { try CaptureSession.start(options) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let session):
                    if answered {
                        // Таймаут уже сообщён во Flutter, а устройство всё-таки стартовало:
                        // запись никому не нужна, останавливаем.
                        self.controlQueue.async { _ = session.stop() }
                        return
                    }
                    self.starting = false
                    self.session = session
                    answer(session.info)
                case .failure(let error):
                    self.starting = false
                    answer(FlutterError(code: "start", message: "\(error)", details: nil))
                }
            }
        }
    }

    private func stop(result: @escaping FlutterResult) {
        guard let session else {
            result(["files": [[String: Any]](), "tail": [String: Any]()])
            return
        }
        // Уровни перестают читать сессию сразу, остановка устройств — на фоновой очереди.
        self.session = nil
        controlQueue.async {
            let files = session.stop()
            // Хвост записи обработан уже после отключения сессии от канала audio —
            // отдаём его вместе с итогом, чтобы расшифровка на лету ничего не потеряла.
            var tail: [String: Any] = [:]
            for (channel, queue) in [("mic", session.micSamples), ("system", session.systemSamples)] {
                let samples = queue.take()
                if !samples.isEmpty {
                    tail[channel] = FlutterStandardTypedData(float32: samples.withUnsafeBufferPointer { Data(buffer: $0) })
                }
            }
            DispatchQueue.main.async { result(["files": files, "tail": tail]) }
        }
    }

    // MARK: - Уровни

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        levelSink = events
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let sink = self.levelSink, let session = self.session else { return }
            var levels: [String: Any] = [:]
            // -inf (тишина) через канал не передать: отдаём -120 дБ.
            if let level = session.systemSink?.takeLevel() { levels["system"] = Double(level.isFinite ? level : -120) }
            if let level = session.micSink?.takeLevel() { levels["mic"] = Double(level.isFinite ? level : -120) }
            if !levels.isEmpty { sink(levels) }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        levelTimer?.invalidate()
        levelTimer = nil
        levelSink = nil
        return nil
    }
}

/// Одна запись: системный звук и/или микрофон. Запуск и остановка блокирующие —
/// вызывать не на главном потоке.
final class CaptureSession {
    struct Options {
        let outDir: URL
        let system: Bool
        let mic: Bool
        let micDevice: String?
        let streamAudio: Bool
    }

    /// Отсчёты для расшифровки на лету; наполняются, только если включён streamAudio.
    let micSamples = SampleQueue()
    let systemSamples = SampleQueue()

    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicCapture?
    private(set) var systemSink: AudioSink?
    private(set) var micSink: AudioSink?
    private(set) var info: [String: Any] = [:]

    static func start(_ options: Options) throws -> CaptureSession {
        let session = CaptureSession()
        // Общий момент начала записи: к нему привязаны обе дорожки.
        let startHostTime = mach_absolute_time()
        do {
            try FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)
            // Микрофон — первым. На macOS 26 aggregate с tap не запускает IO, пока
            // в системе ничего не играет, и если он стартовал раньше, AudioDeviceStart
            // микрофона не возвращается, а coreaudiod виснет до перезапуска.
            if options.mic {
                guard let device = try chooseMic(options.micDevice) else {
                    throw CaptureError("нет устройства ввода")
                }
                let capture = MicCapture()
                session.micCapture = capture
                session.micSink = try capture.start(
                    url: options.outDir.appendingPathComponent("mic.wav"), device: device, startHostTime: startHostTime
                )
                if options.streamAudio {
                    let queue = session.micSamples
                    session.micSink?.onSamples = { queue.append($0) }
                }
                session.info["micDevice"] = device.name
                session.info["micIsBluetooth"] = device.isBluetooth
            }
            if options.system {
                let capture = SystemAudioCapture()
                session.systemCapture = capture
                session.systemSink = try capture.start(
                    url: options.outDir.appendingPathComponent("system.wav"), startHostTime: startHostTime
                )
                if options.streamAudio {
                    let queue = session.systemSamples
                    session.systemSink?.onSamples = { queue.append($0) }
                }
            }
            return session
        } catch {
            _ = session.stop()
            throw error
        }
    }

    private static func chooseMic(_ query: String?) throws -> AudioDevices.Device? {
        guard let query else { return AudioDevices.defaultInput() }
        let inputs = AudioDevices.inputs()
        guard let match = inputs.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
            throw CaptureError("микрофон «\(query)» не найден. Доступны: \(inputs.map(\.name).joined(separator: ", "))")
        }
        return match
    }

    /// Останавливает запись и возвращает итог по каждому файлу.
    func setPaused(_ paused: Bool) {
        micCapture?.setPaused(paused)
        systemCapture?.setPaused(paused)
    }

    func stop() -> [[String: Any]] {
        let endHostTime = mach_absolute_time()
        micCapture?.stop(endHostTime: endHostTime)
        systemCapture?.stop(endHostTime: endHostTime)
        systemCapture = nil
        micCapture = nil
        let files = [systemSink, micSink].compactMap { $0 }.map { sink -> [String: Any] in
            sink.close()
            return ["channel": sink.name, "path": sink.url.path, "seconds": sink.seconds, "peak": Double(sink.peak)]
        }
        systemSink = nil
        micSink = nil
        return files
    }
}

/// Накопитель отсчётов: пишет очередь обработки записи, забирает главный поток.
final class SampleQueue {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let taken = samples
        samples.removeAll(keepingCapacity: true)
        return taken
    }
}

/// Канал `meet_capture/audio`: раз в 100 мс отдаёт накопленные отсчёты каждого канала
/// как {"channel": "mic"|"system", "samples": Float32List}.
private final class AudioStreamHandler: NSObject, FlutterStreamHandler {
    private weak var plugin: MeetCapturePlugin?
    private var sink: FlutterEventSink?
    private var timer: Timer?

    init(plugin: MeetCapturePlugin) {
        self.plugin = plugin
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.flush() }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        timer?.invalidate()
        timer = nil
        sink = nil
        return nil
    }

    private func flush() {
        guard let sink, let session = plugin?.session else { return }
        for (channel, queue) in [("mic", session.micSamples), ("system", session.systemSamples)] {
            let samples = queue.take()
            guard !samples.isEmpty else { continue }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            sink(["channel": channel, "samples": FlutterStandardTypedData(float32: data)])
        }
    }
}
