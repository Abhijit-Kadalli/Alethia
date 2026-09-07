import Foundation

/// One block of mixed audio plus per-source loudness, used both for live transcription
/// and for deciding later whether a stretch of speech came from the local microphone
/// (the user) or from system audio (remote participants).
public struct MixedChunk: Sendable, Equatable {
    /// Mixed mono samples at the mixer's sample rate.
    public var samples: [Float]
    /// Offset of `samples[0]` from the start of the recording, in samples.
    public var startSample: Int
    public var microphoneRMS: Float
    public var systemRMS: Float

    public init(samples: [Float], startSample: Int, microphoneRMS: Float, systemRMS: Float) {
        self.samples = samples
        self.startSample = startSample
        self.microphoneRMS = microphoneRMS
        self.systemRMS = systemRMS
    }
}

/// Per-hop loudness of each source, kept for the whole recording. ~100 ms resolution means
/// an hour costs well under 100 KB.
public struct SourceActivityFrame: Sendable, Equatable, Codable {
    public var startMs: Int
    public var endMs: Int
    public var microphoneRMS: Float
    public var systemRMS: Float

    public init(startMs: Int, endMs: Int, microphoneRMS: Float, systemRMS: Float) {
        self.startMs = startMs
        self.endMs = endMs
        self.microphoneRMS = microphoneRMS
        self.systemRMS = systemRMS
    }
}

/// Combines the microphone stream and (optionally) the system-audio stream into a single
/// mono stream on a shared timeline.
///
/// Both sources arrive on their own threads at their own cadence. The mixer buffers each
/// and emits fixed-size hops once both have enough samples. If one source stalls (system
/// audio produces nothing while no app plays sound, a device was unplugged, …) the mixer
/// waits up to `maxLagSamples` and then pads the lagging source with silence so the
/// timeline keeps moving and the other source is never delayed indefinitely.
///
/// Thread-safe. `onChunk` is invoked synchronously on whichever thread pushed the sample
/// that completed a hop.
public final class AudioMixer: @unchecked Sendable {
    public enum Source: Sendable {
        case microphone
        case system
    }

    public let sampleRate: Int
    public let hopSize: Int
    public let includesSystemAudio: Bool
    /// How far one source may run ahead before the other is padded with silence.
    public let maxLagSamples: Int
    public var microphoneGain: Float = 1.0
    public var systemGain: Float = 1.0

    public var onChunk: ((MixedChunk) -> Void)?

    private let lock = NSLock()
    private var micQueue: [Float] = []
    private var sysQueue: [Float] = []
    private var emitted = 0
    private var activity: [SourceActivityFrame] = []

    public init(sampleRate: Int = 16_000, hopMilliseconds: Int = 100, includesSystemAudio: Bool, maxLagMilliseconds: Int = 400) {
        self.sampleRate = sampleRate
        self.hopSize = max(1, sampleRate * hopMilliseconds / 1000)
        self.includesSystemAudio = includesSystemAudio
        self.maxLagSamples = max(hopSize, sampleRate * maxLagMilliseconds / 1000)
    }

    /// Total samples emitted so far.
    public var emittedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return emitted
    }

    public var activityTimeline: [SourceActivityFrame] {
        lock.lock(); defer { lock.unlock() }
        return activity
    }

    public func push(_ samples: [Float], from source: Source) {
        guard !samples.isEmpty else { return }
        var ready: [MixedChunk] = []
        lock.lock()
        switch source {
        case .microphone:
            micQueue.append(contentsOf: samples)
        case .system:
            guard includesSystemAudio else { lock.unlock(); return }
            sysQueue.append(contentsOf: samples)
        }
        drainLocked(into: &ready, flushing: false)
        lock.unlock()
        for chunk in ready { onChunk?(chunk) }
    }

    /// Emits whatever is buffered (padding the shorter source), e.g. when recording stops.
    public func flush() {
        var ready: [MixedChunk] = []
        lock.lock()
        drainLocked(into: &ready, flushing: true)
        lock.unlock()
        for chunk in ready { onChunk?(chunk) }
    }

    private func drainLocked(into ready: inout [MixedChunk], flushing: Bool) {
        if !includesSystemAudio {
            while micQueue.count >= hopSize || (flushing && !micQueue.isEmpty) {
                let take = min(hopSize, micQueue.count)
                let mic = Array(micQueue.prefix(take))
                micQueue.removeFirst(take)
                let rms = Self.rms(mic)
                ready.append(makeChunk(samples: mic.map { $0 * microphoneGain }, micRMS: rms, sysRMS: 0))
            }
            return
        }

        while true {
            let micCount = micQueue.count
            let sysCount = sysQueue.count
            let both = min(micCount, sysCount)

            if both >= hopSize {
                ready.append(mixHopLocked(micTake: hopSize, sysTake: hopSize))
                continue
            }

            // One source is starved. Pad it once the other is far enough ahead (or on flush).
            let lag = abs(micCount - sysCount)
            if flushing || lag >= maxLagSamples {
                let take = min(hopSize, max(micCount, sysCount))
                guard take > 0 else { break }
                ready.append(mixHopLocked(micTake: min(take, micCount), sysTake: min(take, sysCount), hop: take))
                if flushing, micQueue.isEmpty, sysQueue.isEmpty { break }
                continue
            }
            break
        }
    }

    private func mixHopLocked(micTake: Int, sysTake: Int, hop: Int? = nil) -> MixedChunk {
        let n = hop ?? hopSize
        var mixed = [Float](repeating: 0, count: n)
        var micEnergy: Float = 0
        var sysEnergy: Float = 0

        if micTake > 0 {
            for i in 0..<micTake {
                let s = micQueue[i]
                micEnergy += s * s
                mixed[i] += s * microphoneGain
            }
            micQueue.removeFirst(micTake)
        }
        if sysTake > 0 {
            for i in 0..<sysTake {
                let s = sysQueue[i]
                sysEnergy += s * s
                mixed[i] += s * systemGain
            }
            sysQueue.removeFirst(sysTake)
        }
        for i in 0..<n {
            mixed[i] = Self.softClip(mixed[i])
        }
        let micRMS = micTake > 0 ? (micEnergy / Float(micTake)).squareRoot() : 0
        let sysRMS = sysTake > 0 ? (sysEnergy / Float(sysTake)).squareRoot() : 0
        return makeChunk(samples: mixed, micRMS: micRMS, sysRMS: sysRMS)
    }

    private func makeChunk(samples: [Float], micRMS: Float, sysRMS: Float) -> MixedChunk {
        let start = emitted
        emitted += samples.count
        let startMs = start * 1000 / sampleRate
        let endMs = emitted * 1000 / sampleRate
        activity.append(SourceActivityFrame(startMs: startMs, endMs: endMs, microphoneRMS: micRMS, systemRMS: sysRMS))
        return MixedChunk(samples: samples, startSample: start, microphoneRMS: micRMS, systemRMS: sysRMS)
    }

    /// Gentle limiter: linear up to ±0.8, then compresses toward ±1.
    static func softClip(_ x: Float) -> Float {
        let threshold: Float = 0.8
        let a = abs(x)
        if a <= threshold { return x }
        let over = a - threshold
        let compressed = threshold + (1 - threshold) * (1 - exp(-over / (1 - threshold)))
        return x < 0 ? -compressed : compressed
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

public extension Array where Element == SourceActivityFrame {
    /// Decides whether a time range was dominated by the local microphone.
    ///
    /// Returns nil when neither source had meaningful energy or the two are too close to call.
    func microphoneDominates(startMs: Int, endMs: Int, margin: Float = 1.6) -> Bool? {
        var mic: Float = 0
        var sys: Float = 0
        var count = 0
        for frame in self where frame.endMs > startMs && frame.startMs < endMs {
            mic += frame.microphoneRMS
            sys += frame.systemRMS
            count += 1
        }
        guard count > 0 else { return nil }
        let floor: Float = 0.004
        if mic < floor && sys < floor { return nil }
        if mic > sys * margin { return true }
        if sys > mic * margin { return false }
        return nil
    }
}
