import AudioToolbox
import os

/// Кольцевой буфер Float-отсчётов (чередующиеся каналы) между IOProc и обработкой.
/// Память выделяется заранее: в аудиопотоке нет аллокаций, диска и тяжёлых вычислений,
/// только memcpy под коротким os_unfair_lock.
///
/// Кроме отсчётов хранит отметки о пропусках («здесь не хватает N кадров»):
/// их ставит IOProc, когда устройство молчало, а обработка вставляет на их место
/// тишину. Нули в аудиопотоке не пишутся — пропуск может длиться минутами.
/// И отметки о смене частоты («дальше кадры идут с частотой R»): AirPods, включая
/// микрофон, переходят с 48 на 24 или 16 кГц.
final class FloatRing {
    enum ReadResult {
        case samples(Int)
        case silence(Int)
        case rate(Double)
        case empty
    }

    let channels: Int
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var readIndex = 0
    private var count = 0
    private(set) var droppedFrames = 0

    /// Позиции считаются в кадрах от начала записи.
    private var framesWritten = 0
    private var framesRead = 0
    private static let maxGaps = 256
    private let gapPositions: UnsafeMutablePointer<Int>
    private let gapLengths: UnsafeMutablePointer<Int>
    private var gapHead = 0
    private var gapCount = 0
    private static let maxRates = 16
    private let ratePositions: UnsafeMutablePointer<Int>
    private let rateValues: UnsafeMutablePointer<Double>
    private var rateHead = 0
    private var rateCount = 0

    init(channels: Int, capacityFrames: Int) {
        self.channels = channels
        capacity = capacityFrames * channels
        storage = .allocate(capacity: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        gapPositions = .allocate(capacity: Self.maxGaps)
        gapLengths = .allocate(capacity: Self.maxGaps)
        ratePositions = .allocate(capacity: Self.maxRates)
        rateValues = .allocate(capacity: Self.maxRates)
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
        gapPositions.deallocate()
        gapLengths.deallocate()
        ratePositions.deallocate()
        rateValues.deallocate()
    }

    /// Вызывается из IOProc. Если буфер полон, новые кадры отбрасываются.
    func write(_ list: UnsafeMutableAudioBufferListPointer, firstBuffer: Int, frames: Int, interleaved: Bool) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let free = (capacity - count) / channels
        let n = min(frames, free)
        droppedFrames += frames - n
        guard n > 0 else { return }

        var writeIndex = (readIndex + count) % capacity
        if interleaved {
            guard let src = list[firstBuffer].mData?.assumingMemoryBound(to: Float.self) else { return }
            let total = n * channels
            let first = min(total, capacity - writeIndex)
            (storage + writeIndex).update(from: src, count: first)
            if first < total { storage.update(from: src + first, count: total - first) }
        } else {
            for frame in 0..<n {
                for ch in 0..<channels {
                    let src = list[firstBuffer + ch].mData?.assumingMemoryBound(to: Float.self)
                    storage[writeIndex] = src?[frame] ?? 0
                    writeIndex = (writeIndex + 1) % capacity
                }
            }
        }
        count += n * channels
        framesWritten += n
    }

    /// Отмечает, что перед следующими кадрами не хватает `frames` кадров тишины.
    /// Вызывается из IOProc или после остановки устройства.
    func addGap(frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let last = (gapHead + gapCount - 1) % Self.maxGaps
        if gapCount > 0, gapPositions[last] == framesWritten {
            gapLengths[last] += frames
        } else if gapCount < Self.maxGaps {
            let slot = (gapHead + gapCount) % Self.maxGaps
            gapPositions[slot] = framesWritten
            gapLengths[slot] = frames
            gapCount += 1
        } else {
            droppedFrames += frames
        }
    }

    /// Отмечает, что следующие кадры идут с частотой `rate`. Вызывается из IOProc.
    func addRateChange(_ rate: Double) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let last = (rateHead + rateCount - 1) % Self.maxRates
        if rateCount > 0, ratePositions[last] == framesWritten {
            rateValues[last] = rate
        } else if rateCount < Self.maxRates {
            let slot = (rateHead + rateCount) % Self.maxRates
            ratePositions[slot] = framesWritten
            rateValues[slot] = rate
            rateCount += 1
        }
    }

    /// Вызывается из очереди обработки: либо новая частота, либо отсчёты (до следующей
    /// отметки), либо длина тишины, которую надо вставить.
    func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> ReadResult {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        if rateCount > 0, ratePositions[rateHead] == framesRead {
            let rate = rateValues[rateHead]
            rateHead = (rateHead + 1) % Self.maxRates
            rateCount -= 1
            return .rate(rate)
        }
        if gapCount > 0, gapPositions[gapHead] == framesRead {
            let frames = gapLengths[gapHead]
            gapHead = (gapHead + 1) % Self.maxGaps
            gapCount -= 1
            return .silence(frames)
        }
        var n = min(maxFrames, count / channels)
        if gapCount > 0 { n = min(n, gapPositions[gapHead] - framesRead) }
        if rateCount > 0 { n = min(n, ratePositions[rateHead] - framesRead) }
        guard n > 0 else { return .empty }

        let total = n * channels
        let first = min(total, capacity - readIndex)
        dst.update(from: storage + readIndex, count: first)
        if first < total { (dst + first).update(from: storage, count: total - first) }
        readIndex = (readIndex + total) % capacity
        count -= total
        framesRead += n
        return .samples(n)
    }
}
