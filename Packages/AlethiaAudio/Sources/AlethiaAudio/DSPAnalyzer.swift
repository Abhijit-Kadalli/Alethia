import Foundation
import AlethiaCore

/// Frame-level classical DSP features used before neural VAD.
public struct DSPFrameFeatures: Sendable {
    public var rms: Float
    public var zeroCrossingRate: Float
    public var spectralFlatness: Float
    public var speechBandRatio: Float

    public var passesNoiseGate: Bool {
        rms > 0.008 && spectralFlatness < 0.55 && speechBandRatio > 0.25
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

        // Lightweight magnitude spectrum via Goertzel-ish band energies (no Accelerate dependency here
        // so the algorithm matches the Python reference). Production Mac path can use vDSP.
        let bands = bandEnergies(frame: frame, sampleRate: sampleRate)
        let geo = exp(bands.map { log(max($0, 1e-12)) }.reduce(0, +) / Float(bands.count))
        let arith = bands.reduce(0, +) / Float(bands.count)
        let flatness = arith > 0 ? geo / arith : 1

        let speech = (bands[1] + bands[2]) // ~300–3400 Hz proxies
        let total = max(bands.reduce(0, +), 1e-12)
        let ratio = speech / total

        return DSPFrameFeatures(
            rms: rms,
            zeroCrossingRate: zcr,
            spectralFlatness: flatness,
            speechBandRatio: ratio
        )
    }

    private static func bandEnergies(frame: [Float], sampleRate: Double) -> [Float] {
        // Four coarse bands: 0-300, 300-1000, 1000-3400, 3400-Nyquist via FIR-ish box filters on blocks.
        let n = frame.count
        let nyquist = sampleRate / 2
        let edges: [Double] = [0, 300, 1000, 3400, nyquist]
        var energies = Array(repeating: Float(0), count: edges.count - 1)

        // Simple DFT bins for small frames (n ~ 480). Fine for gating; not for full spectrograms.
        let half = n / 2
        for k in 1..<half {
            let freq = Double(k) * sampleRate / Double(n)
            var re: Float = 0
            var im: Float = 0
            let w = 2 * Float.pi * Float(k) / Float(n)
            for t in 0..<n {
                let angle = w * Float(t)
                re += frame[t] * cos(angle)
                im -= frame[t] * sin(angle)
            }
            let mag2 = re * re + im * im
            for b in 0..<energies.count {
                if freq >= edges[b] && freq < edges[b + 1] {
                    energies[b] += mag2
                    break
                }
            }
        }
        return energies
    }
}
