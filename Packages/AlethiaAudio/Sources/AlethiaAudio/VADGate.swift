import Foundation
import AlethiaCore

public enum SpeechState: String, Sendable {
    case silence
    case speech
}

/// Hysteresis VAD state machine. Neural probabilities come from Silero (or a stub).
public final class VADGate: @unchecked Sendable {
    private let config: PipelineConfig
    private var state: SpeechState = .silence
    private var openMs = 0
    private var closeMs = 0

    public init(config: PipelineConfig = .default) {
        self.config = config
    }

    public var currentState: SpeechState { state }

    /// Feed one frame probability (and whether classical DSP passed). Returns new state.
    @discardableResult
    public func process(probability: Float, dspPassed: Bool, frameMs: Int) -> SpeechState {
        let p = dspPassed ? probability : min(probability, 0.2)

        switch state {
        case .silence:
            if p >= config.vadOpenThreshold {
                openMs += frameMs
                if openMs >= config.openSpeechMs {
                    state = .speech
                    openMs = 0
                    closeMs = 0
                }
            } else {
                openMs = 0
            }
        case .speech:
            if p <= config.vadCloseThreshold {
                closeMs += frameMs
                if closeMs >= config.closeSilenceMs {
                    state = .silence
                    closeMs = 0
                    openMs = 0
                }
            } else {
                closeMs = 0
            }
        }
        return state
    }

    public func reset() {
        state = .silence
        openMs = 0
        closeMs = 0
    }
}

/// Placeholder Silero front-end. Replace with GGML/CoreML Silero weights at runtime.
public protocol SpeechProbabilityModel: Sendable {
    func probability(frame: [Float]) -> Float
}

public struct EnergyVADStub: SpeechProbabilityModel {
    public init() {}
    public func probability(frame: [Float]) -> Float {
        let features = DSPAnalyzer.analyze(frame: frame)
        if !features.passesNoiseGate { return 0.05 }
        // Map RMS into a soft probability for development without Silero weights.
        let x = min(max((features.rms - 0.008) / 0.05, 0), 1)
        return 0.2 + 0.75 * x
    }
}
