import Foundation
import AlethiaCore

/// Frame-level classical DSP features used before neural VAD.
public struct DSPFrameFeatures: Sendable {
    public var rms: Float
    public var zeroCrossingRate: Float
    /// Bin-wise spectral flatness (Hann + power spectrum, DC skipped). Noise → high, speech → low.
    public var spectralFlatness: Float
    /// Soft energy share in ~85–5500 Hz (includes male F0).
    public var speechBandRatio: Float

    /// Absolute high-recall floor without adaptive context (tests / static checks).
    public var passesNoiseGate: Bool {
        rms >= 0.004
    }
}

public enum DSPAnalyzer {
    /// Analyze a mono Float32 frame (typically 20–30 ms @ 16 kHz).
    public static func analyze(frame: [Float], sampleRate: Double = 16_000) -> DSPFrameFeatures {
        guard !frame.isEmpty else {
            return DSPFrameFeatures(rms: 0, zeroCrossingRate: 0, spectralFlatness: 1, speechBandRatio: 0)
        }

        var sumSquares: Float = 0
        var crossings = 0
        for i in 0..<frame.count {
            let s = frame[i]
            sumSquares += s * s
            if i > 0, (frame[i - 1] >= 0) != (s >= 0) { crossings += 1 }
        }
        let rms = sqrt(sumSquares / Float(frame.count))
        let zcr = Float(crossings) / Float(max(frame.count - 1, 1))

        let spectrum = powerSpectrum(frame: frame)
        let flatness = spectralFlatness(power: spectrum.power)
        let ratio = speechBandRatio(
            power: spectrum.power,
            sampleRate: sampleRate,
            nFFT: spectrum.nFFT,
            lowHz: 85,
            highHz: 5500
        )

        return DSPFrameFeatures(
            rms: rms,
            zeroCrossingRate: zcr,
            spectralFlatness: flatness,
            speechBandRatio: ratio
        )
    }

    /// Whether a frame looks noise-like enough to update the adaptive floor.
    public static func isNoiseLike(_ features: DSPFrameFeatures) -> Bool {
        features.spectralFlatness >= 0.35 || features.speechBandRatio < 0.12
    }

    // MARK: - Spectrum

    private struct Spectrum {
        var power: [Float]
        var nFFT: Int
    }

    /// Hann-windowed real DFT power (skip storing DC in flatness; index 0 is DC).
    private static func powerSpectrum(frame: [Float]) -> Spectrum {
        let n = frame.count
        var windowed = [Float](repeating: 0, count: n)
        if n == 1 {
            windowed[0] = frame[0]
        } else {
            for i in 0..<n {
                let w = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n - 1))
                windowed[i] = frame[i] * w
            }
        }

        let half = n / 2
        var power = [Float](repeating: 0, count: half + 1)
        for k in 0...half {
            var re: Float = 0
            var im: Float = 0
            let w = 2 * Float.pi * Float(k) / Float(n)
            for t in 0..<n {
                let angle = w * Float(t)
                re += windowed[t] * cos(angle)
                im -= windowed[t] * sin(angle)
            }
            power[k] = re * re + im * im
        }
        return Spectrum(power: power, nFFT: n)
    }

    private static func spectralFlatness(power: [Float]) -> Float {
        // Skip DC (bin 0).
        guard power.count > 2 else { return 1 }
        let bins = power[1...]
        var logSum: Float = 0
        var arith: Float = 0
        var count: Float = 0
        for p in bins {
            let v = max(p, 1e-12)
            logSum += log(v)
            arith += v
            count += 1
        }
        guard count > 0, arith > 0 else { return 1 }
        let geo = exp(logSum / count)
        return min(max(geo / (arith / count), 0), 1)
    }

    private static func speechBandRatio(
        power: [Float],
        sampleRate: Double,
        nFFT: Int,
        lowHz: Double,
        highHz: Double
    ) -> Float {
        guard power.count > 1, nFFT > 0 else { return 0 }
        var speech: Float = 0
        var total: Float = 0
        for k in 1..<power.count {
            let freq = Double(k) * sampleRate / Double(nFFT)
            let p = power[k]
            total += p
            if freq >= lowHz && freq < highHz {
                speech += p
            }
        }
        return speech / max(total, 1e-12)
    }
}
