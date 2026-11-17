import AVFoundation

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Приводит поток к 16 кГц моно (формат для ASR), пишет в WAV и считает уровень сигнала.
final class AudioSink {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    let name: String
    let url: URL
    private(set) var inputFormat: AVAudioFormat
    private var converter: AVAudioConverter

    /// Смены частоты входа за запись — для журнала («12,3 с: 48000 → 24000 Гц»).
    private(set) var rateChanges: [String] = []
    private var file: AVAudioFile?
    private let lock = NSLock()

    /// Получает уже приведённые к 16 кГц моно отсчёты — для расшифровки на лету.
    /// Вызывается из очереди обработки, не из аудиопотока; задавать до старта записи.
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)?

    private var sumSquares: Double = 0
    private var levelFrames: Int = 0
    private var peakSinceStart: Float = 0
    private(set) var framesWritten: Int64 = 0

    init(name: String, inputFormat: AVAudioFormat, url: URL) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw CaptureError("\(name): не удалось создать конвертер из \(inputFormat)")
        }
        converter.downmix = true
        self.name = name
        self.url = url
        self.inputFormat = inputFormat
        self.converter = converter

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
    }

    var inputDescription: String {
        "\(Int(inputFormat.sampleRate)) Гц, \(inputFormat.channelCount) кан."
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return }
        emit(out)
    }

    /// Вход дальше идёт с частотой [rate]: досводим то, что конвертер держит внутри, и
    /// перестраиваем его. Без этого звук после смены частоты (AirPods включили микрофон —
    /// 48 → 24 кГц) пересчитывался бы по старой и выходил ускоренным вдвое, а конец
    /// дорожки — тишиной. Вызывается из очереди обработки; [format] — новый формат входа.
    func changeInput(to format: AVAudioFormat) {
        guard format.sampleRate != inputFormat.sampleRate || format.channelCount != inputFormat.channelCount,
              let next = AVAudioConverter(from: format, to: Self.targetFormat)
        else { return }
        if let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: 4096) {
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            emit(out)
        }
        next.downmix = true
        rateChanges.append(String(format: "%.1f с: %.0f → %.0f Гц", seconds, inputFormat.sampleRate, format.sampleRate))
        FileHandle.standardError.write("\(name): частота входа \(rateChanges.last!)\n".data(using: .utf8)!)
        inputFormat = format
        converter = next
    }

    /// Отсчёты 16 кГц — в поток расшифровки, в файл и в уровень.
    private func emit(_ out: AVAudioPCMBuffer) {
        guard out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
        onSamples?(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))

        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        do {
            try file.write(from: out)
            framesWritten += Int64(out.frameLength)
        } catch {
            FileHandle.standardError.write("\(name): ошибка записи: \(error)\n".data(using: .utf8)!)
        }
        for i in 0..<Int(out.frameLength) {
            let s = samples[i]
            sumSquares += Double(s * s)
            peakSinceStart = max(peakSinceStart, abs(s))
        }
        levelFrames += Int(out.frameLength)
    }

    /// RMS в dBFS с момента прошлого вызова; nil, если данных не было.
    func takeLevel() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard levelFrames > 0 else { return nil }
        let rms = sqrt(sumSquares / Double(levelFrames))
        sumSquares = 0
        levelFrames = 0
        return rms > 0 ? Float(20 * log10(rms)) : -.infinity
    }

    /// Пиковое значение с начала записи; ровно 0 означает цифровую тишину.
    var peak: Float {
        lock.lock()
        defer { lock.unlock() }
        return peakSinceStart
    }

    var seconds: Double { Double(framesWritten) / Self.targetFormat.sampleRate }

    /// Закрывает файл: AVAudioFile дописывает заголовок WAV при освобождении.
    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}
