import Foundation

public struct SpeechAssessment: Sendable {
    public var probability: Float
    public var energyPassed: Bool
    public var features: DSPFrameFeatures

    public init(probability: Float, energyPassed: Bool, features: DSPFrameFeatures) {
        self.probability = probability
        self.energyPassed = energyPassed
        self.features = features
    }
}

/// Classical high-recall speech probability (Silero can wrap/replace later).
public final class ClassicalSpeechScorer: SpeechProbabilityModel, @unchecked Sendable {
    private let noiseFloor = AdaptiveNoiseFloor()
    private let lock = NSLock()

    public init() {}

    public func assess(frame: [Float], sampleRate: Double = 16_000) -> SpeechAssessment {
        lock.lock()
        defer { lock.unlock() }

        let features = DSPAnalyzer.analyze(frame: frame, sampleRate: sampleRate)
        let noiseLike = DSPAnalyzer.isNoiseLike(features)
        noiseFloor.update(rms: features.rms, noiseLike: noiseLike)

        let energyPassed = noiseFloor.energyPassed(rms: features.rms)
        var p = Self.score(features: features, energyPassed: energyPassed, floor: noiseFloor.floor)

        // Hard caps: white-ish noise and sub-bass rumble (energy below ~85 Hz).
        if features.spectralFlatness >= 0.40 {
            p = min(p, 0.28)
        }
        if features.spectralFlatness < 0.25 && features.speechBandRatio < 0.08 {
            p = min(p, 0.22)
        }
        if !energyPassed {
            p = min(p, 0.20)
        }

        return SpeechAssessment(probability: p, energyPassed: energyPassed, features: features)
    }

    public func probability(frame: [Float]) -> Float {
        assess(frame: frame).probability
    }

    public func reset() {
        lock.lock()
        noiseFloor.reset()
        lock.unlock()
    }

    /// energy × structure(SFM, speech band) + ZCR boost for unvoiced paths.
    private static func score(features: DSPFrameFeatures, energyPassed: Bool, floor: Float) -> Float {
        guard energyPassed else { return 0.05 }

        let thresh = max(0.004 as Float, 1.8 * floor)
        let energy = min(max((features.rms - thresh) / max(0.04, thresh * 3), 0), 1)

        // Low flatness + speech-band energy → structured (speech-like).
        let sfmStructure = min(max(1 - features.spectralFlatness / 0.55, 0), 1)
        let bandStructure = min(max((features.speechBandRatio - 0.08) / 0.55, 0), 1)
        let structure = 0.55 * sfmStructure + 0.45 * bandStructure

        var p = 0.15 + 0.75 * (0.45 * energy + 0.55 * structure)

        // Unvoiced / fricative path: elevated ZCR with energy still helps.
        if features.zeroCrossingRate > 0.08 && features.zeroCrossingRate < 0.45 {
            p += 0.08 * min(features.zeroCrossingRate / 0.25, 1)
        }

        return min(max(p, 0), 1)
    }
}

/// Placeholder Silero front-end. Classical scorer is the default until GGML Silero is wired.
public protocol SpeechProbabilityModel: Sendable {
    func probability(frame: [Float]) -> Float
    func assess(frame: [Float], sampleRate: Double) -> SpeechAssessment
}

public extension SpeechProbabilityModel {
    func assess(frame: [Float], sampleRate: Double = 16_000) -> SpeechAssessment {
        let features = DSPAnalyzer.analyze(frame: frame, sampleRate: sampleRate)
        let p = probability(frame: frame)
        return SpeechAssessment(
            probability: p,
            energyPassed: features.passesNoiseGate,
            features: features
        )
    }
}

/// Backward-compatible name used by AmbientPipeline defaults.
public typealias EnergyVADStub = ClassicalSpeechScorer
