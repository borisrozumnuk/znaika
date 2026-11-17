import AVFoundation
import CoreAudio
import os

/// Запись входа Core Audio-устройства через IOProc.
///
/// IOProc в аудиопотоке только копирует отсчёты в кольцевой буфер; конвертация
/// и запись на диск идут в отдельной очереди. Так запись не задерживает
/// IO-цикл и не портит звук другим приложениям.
///
/// Частота устройства может смениться посреди записи (AirPods, включая микрофон, уходят
/// в режим гарнитуры: 48 → 24 или 16 кГц — и у микрофона, и у устройства вывода, а с ним
/// и у aggregate системного звука). Её отслеживает слушатель свойства устройства, IOProc
/// ставит в кольцевой буфер отметку, а обработка перестраивает конвертер с этого места.
///
/// Все каналы записи привязаны к общему моменту старта по системным часам:
/// если устройство какое-то время не отдавало данные (tap на macOS 26 молчит,
/// пока в системе ничего не играет), на это место пишется тишина. Иначе
/// дорожки «Я» и «Собеседники» разъедутся по времени.
final class DeviceRecorder {
    /// Какие буферы входа брать: у устройства их может быть несколько (по одному на поток).
    enum BufferPick {
        /// Первые — основной поток микрофона.
        case first
        /// Последние — tap в aggregate-устройстве идёт после входов подустройств.
        case last
    }

    let sink: AudioSink
    private let deviceID: AudioDeviceID
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue: DispatchQueue
    private let processingQueue: DispatchQueue
    private var drainTimer: DispatchSourceTimer?
    private let ring: FloatRing
    private var chunk: AVAudioPCMBuffer
    private let timeline: Timeline
    private let rate: RateBox
    private let listenerQueue: DispatchQueue
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let pause = PauseFlag()
    private let label: String
    private let debug = ProcessInfo.processInfo.environment["CAPTURE_DEBUG"] != nil

    /// format — формат входа: Float32 PCM, как его отдаёт HAL.
    /// startHostTime — общий для всех каналов момент начала записи (mach_absolute_time).
    init(
        label: String, deviceID: AudioDeviceID, format asbd: AudioStreamBasicDescription,
        pick: BufferPick, startHostTime: UInt64, url: URL
    ) throws {
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32
        else {
            throw CaptureError("\(label): ожидался Float32 PCM, получено: \(asbd)")
        }
        let channels = Int(asbd.mChannelsPerFrame)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // Дальше по конвейеру данные всегда идут чередующимися каналами из кольцевого буфера.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(channels), interleaved: true
        ), let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(asbd.mSampleRate / 10))
        else {
            throw CaptureError("\(label): неподдерживаемый формат: \(asbd)")
        }

        self.label = label
        self.deviceID = deviceID
        self.chunk = chunk
        sink = try AudioSink(name: label, inputFormat: format, url: url)
        // 4 секунды запаса: обработка может ненадолго отстать без потери звука.
        ring = FloatRing(channels: channels, capacityFrames: Int(asbd.mSampleRate) * 4)
        timeline = Timeline(startHostTime: startHostTime, sampleRate: asbd.mSampleRate)
        rate = RateBox(asbd.mSampleRate)
        ioQueue = DispatchQueue(label: "capture-proto.\(label).io", qos: .userInteractive)
        processingQueue = DispatchQueue(label: "capture-proto.\(label).processing", qos: .userInitiated)
        listenerQueue = DispatchQueue(label: "capture-proto.\(label).rate")

        let ring = ring
        let timeline = timeline
        let pause = pause
        let rate = rate
        // Частота, с которой IOProc отдал прошлый буфер, и её оценка по часам: только в IOProc.
        let ioRate = IORate(asbd.mSampleRate)
        let measured = RateMeter()
        let bufferCount = interleaved ? 1 : channels
        let bytesPerFrame = interleaved ? channels * 4 : 4
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, ioQueue) { _, inInputData, inInputTime, _, _ in
                let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                guard input.count >= bufferCount else { return }
                let first = pick == .first ? 0 : input.count - bufferCount
                let frames = Int(input[first].mDataByteSize) / bytesPerFrame
                let time = inInputTime.pointee
                // Запасной путь, если устройство не сообщило о смене частоты: оценка по тому,
                // сколько кадров приходит за секунду в идущих подряд буферах.
                if time.mFlags.contains(.hostTimeValid), !pause.isPaused,
                   let estimate = measured.add(frames: frames, hostTime: time.mHostTime),
                   estimate != rate.value {
                    rate.value = estimate
                }
                let current = rate.value
                if current != ioRate.value {
                    ioRate.value = current
                    ring.addRateChange(current)
                    timeline.setRate(current)
                }
                // Пауза: звук не нужен, а его время — не пропуск (тишиной не заполняется).
                if pause.isPaused {
                    if time.mFlags.contains(.hostTimeValid) {
                        timeline.skip(to: time.mHostTime, frames: frames)
                    }
                    return
                }
                if time.mFlags.contains(.hostTimeValid) {
                    ring.addGap(frames: timeline.missingFrames(before: time.mHostTime, frames: frames))
                }
                ring.write(input, firstBuffer: first, frames: frames, interleaved: interleaved)
            },
            "\(label): AudioDeviceCreateIOProcIDWithBlock"
        )
        if debug {
            print("[debug] \(label): \(asbd.mSampleRate) Гц, \(channels) кан., interleaved=\(interleaved)")
        }
    }

    func start() throws {
        // Слушатель — до запуска: включение микрофона AirPods меняет частоту прямо на старте.
        var nominal = Self.nominalRate(deviceID)
        let rate = rate
        let deviceID = deviceID
        let label = label
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            guard let next = Self.nominalRate(deviceID), next != nominal else { return }
            FileHandle.standardError.write("\(label): устройство сменило частоту \(nominal ?? 0) → \(next) Гц\n".data(using: .utf8)!)
            nominal = next
            rate.value = next
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &rateAddress, listenerQueue, listener) == noErr {
            rateListener = listener
        }
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
        try check(AudioDeviceStart(deviceID, ioProcID), "\(label): AudioDeviceStart")
    }

    /// Пауза записи: устройство не останавливается (перезапуск tap на macOS 26 рискован),
    /// звук отбрасывается прямо в IOProc. Время паузы не считается пропуском: tap в тишине
    /// молчит, и без этого после паузы на её место легла бы тишина.
    func setPaused(_ paused: Bool) {
        let now = mach_absolute_time()
        if paused {
            // До паузы tap мог молчать (в системе тишина) — дописываем тишину до этого
            // момента, иначе при продолжении перенос времени перепрыгнет и через неё.
            ring.addGap(frames: timeline.missingFrames(before: now, frames: 0))
        } else {
            timeline.skip(to: now, frames: 0)
        }
        pause.isPaused = paused
    }

    /// endHostTime — общий момент конца записи: до него дорожка дополняется тишиной.
    func stop(endHostTime: UInt64) {
        guard let ioProcID else { return }
        // Остановили на паузе — хвост паузы тоже не дополняется тишиной.
        if pause.isPaused { timeline.skip(to: endHostTime, frames: 0) }
        AudioDeviceStop(deviceID, ioProcID)
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        self.ioProcID = nil
        if let rateListener {
            AudioObjectRemovePropertyListenerBlock(deviceID, &rateAddress, listenerQueue, rateListener)
            self.rateListener = nil
        }
        // IOProc остановлен: timeline больше никто не трогает.
        ring.addGap(frames: timeline.missingFrames(before: endHostTime, frames: 0))
        // Дописываем хвост, оставшийся в кольцевом буфере.
        drainTimer?.cancel()
        drainTimer = nil
        processingQueue.sync { drain() }
        if debug {
            print("[debug] \(label): вставлено тишины \(String(format: "%.1f", timeline.insertedSeconds)) с")
        }
    }

    /// Номинальная частота устройства; nil — не прочитать.
    private static func nominalRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    /// Забирает накопленное из кольцевого буфера, конвертирует и пишет в файл.
    private func drain() {
        loop: while true {
            guard let dst = chunk.floatChannelData?[0] else { return }
            let capacity = Int(chunk.frameCapacity)
            switch ring.read(into: dst, maxFrames: capacity) {
            case .rate(let rate):
                // Дальше — другая частота: свой буфер и конвертер.
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: rate,
                    channels: AVAudioChannelCount(ring.channels), interleaved: true
                ), let next = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10))
                else { continue }
                sink.changeInput(to: format)
                chunk = next
            case .samples(let frames):
                chunk.frameLength = AVAudioFrameCount(frames)
                sink.consume(chunk)
            case .silence(var frames):
                dst.update(repeating: 0, count: capacity * ring.channels)
                while frames > 0 {
                    let n = min(frames, capacity)
                    chunk.frameLength = AVAudioFrameCount(n)
                    sink.consume(chunk)
                    frames -= n
                }
            case .empty:
                break loop
            }
        }
        if debug, ring.droppedFrames > 0 {
            print("[debug] \(label): отброшено кадров: \(ring.droppedFrames)")
        }
    }
}

/// Пауза записи — читается в IOProc, меняется из канала Flutter.
private final class PauseFlag {
    private let lock = NSLock()
    private var paused = false
    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); paused = newValue; lock.unlock() }
    }
}

/// Текущая частота устройства: пишет слушатель свойства, читает IOProc.
private final class RateBox {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var rate: Double
    init(_ rate: Double) {
        self.rate = rate
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    deinit { lock.deallocate() }
    var value: Double {
        get { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return rate }
        set { os_unfair_lock_lock(lock); rate = newValue; os_unfair_lock_unlock(lock) }
    }
}

/// Частота прошлого буфера — только для IOProc (один поток).
private final class IORate {
    var value: Double
    init(_ value: Double) { self.value = value }
}

/// Фактическая частота по системным часам — только для IOProc. Считаются лишь буферы,
/// пришедшие подряд (tap молчит, пока в системе тишина, — эти паузы не в счёт). Через ~1 с
/// подряд идущего звука — ближайшая стандартная частота, если до неё не больше 3%.
final class RateMeter {
    static let standard: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
    private let ticksPerSecond: Double
    private var lastHost: UInt64 = 0
    private var lastFrames = 0
    private var frames = 0
    private var ticks: UInt64 = 0

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }

    /// Буфер из [frames] кадров начался в [hostTime]; не nil — оценка частоты готова.
    func add(frames count: Int, hostTime: UInt64) -> Double? {
        defer {
            lastHost = hostTime
            lastFrames = count
        }
        guard lastHost != 0, hostTime > lastHost, lastFrames > 0 else { return nil }
        let delta = hostTime - lastHost
        // Прошлый буфер длился не дольше 100 мс по любой разумной частоте — иначе это пауза.
        guard Double(delta) < 0.1 * ticksPerSecond else {
            frames = 0
            ticks = 0
            return nil
        }
        frames += lastFrames
        ticks += delta
        guard Double(ticks) >= ticksPerSecond else { return nil }
        let rate = Double(frames) / (Double(ticks) / ticksPerSecond)
        frames = 0
        ticks = 0
        guard let nearest = Self.standard.min(by: { abs($0 - rate) < abs($1 - rate) }),
              abs(nearest - rate) / nearest < 0.03
        else { return nil }
        return nearest
    }
}

/// Сколько кадров пропущено между ожидаемым и фактическим временем буфера.
/// Меняется из IOProc, а при паузе — и из канала Flutter, поэтому под блокировкой.
private final class Timeline {
    private let lock = NSLock()
    private var ticksPerFrame: Double
    private var thresholdFrames: Int
    private let ticksPerSecond: Double
    /// Когда должен начаться следующий буфер, если пропусков нет.
    private var expectedHostTime: UInt64
    private(set) var insertedSeconds = 0.0
    private var sampleRate: Double

    /// Устройство сменило частоту: дальше кадры — другой длительности.
    func setRate(_ rate: Double) {
        lock.lock()
        defer { lock.unlock() }
        sampleRate = rate
        ticksPerFrame = ticksPerSecond / rate
        thresholdFrames = Int(rate * 0.05)
    }

    init(startHostTime: UInt64, sampleRate: Double) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        ticksPerFrame = ticksPerSecond / sampleRate
        // Меньше 50 мс — дрожание отметок времени, а не пропуск.
        thresholdFrames = Int(sampleRate * 0.05)
        expectedHostTime = startHostTime
        self.sampleRate = sampleRate
    }

    /// hostTime — время первого кадра буфера, frames — его длина.
    func missingFrames(before hostTime: UInt64, frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var missing = 0
        if hostTime > expectedHostTime {
            let gap = Int(Double(hostTime - expectedHostTime) / ticksPerFrame)
            if gap > thresholdFrames { missing = gap }
        }
        expectedHostTime = max(expectedHostTime, hostTime) + UInt64(Double(frames) * ticksPerFrame)
        insertedSeconds += Double(missing) / sampleRate
        return missing
    }

    /// Время до hostTime (плюс frames кадров) — пауза, а не пропуск: заполнять нечем.
    func skip(to hostTime: UInt64, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        expectedHostTime = max(expectedHostTime, hostTime + UInt64(Double(frames) * ticksPerFrame))
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else {
        throw CaptureError("\(what) вернул ошибку \(status) (\(fourCC(status)))")
    }
}

private func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "\(status)" }
    return String(decoding: bytes, as: UTF8.self)
}
