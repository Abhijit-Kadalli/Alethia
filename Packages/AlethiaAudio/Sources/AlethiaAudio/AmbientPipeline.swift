import Foundation
import AlethiaCore

/// Owns capture → DSP → VAD → conversation segments for ambient mode.
@MainActor
public final class AmbientPipeline: ObservableObject {
    @Published public private(set) var state: AmbientState = .stopped
    @Published public private(set) var lastLevel: Float = 0

    public var onConversationClosed: ((ConversationSegment) -> Void)?

    private let config: PipelineConfig
    private let capture: MicrophoneCapture
    private let vadModel: SpeechProbabilityModel
    private let vadGate: VADGate
    private let segmenter: ConversationSegmenter
    private var frameBuffer: [Float] = []
    private let samplesPerFrame: Int

    public init(
        config: PipelineConfig = .default,
        capture: MicrophoneCapture = MicrophoneCapture(),
        vadModel: SpeechProbabilityModel = EnergyVADStub()
    ) {
        self.config = config
        self.capture = capture
        self.vadModel = vadModel
        self.vadGate = VADGate(config: config)
        self.segmenter = ConversationSegmenter(config: config)
        self.samplesPerFrame = Int(config.sampleRate * config.frameMs / 1000.0)
    }

    public func start() throws {
        guard state == .stopped || state == .paused else { return }
        capture.onFrames = { [weak self] samples in
            Task { @MainActor in self?.ingest(samples) }
        }
        try capture.start()
        state = .listening
    }

    public func pause() {
        capture.stop()
        state = .paused
    }

    public func stop() {
        if let event = segmenter.forceClose(), case .closed(let seg) = event {
            onConversationClosed?(seg)
        }
        capture.stop()
        vadGate.reset()
        frameBuffer.removeAll(keepingCapacity: true)
        state = .stopped
    }

    private func ingest(_ samples: [Float]) {
        frameBuffer.append(contentsOf: samples)
        let frameMs = Int(config.frameMs)
        while frameBuffer.count >= samplesPerFrame {
            let frame = Array(frameBuffer.prefix(samplesPerFrame))
            frameBuffer.removeFirst(samplesPerFrame)

            let features = DSPAnalyzer.analyze(frame: frame, sampleRate: config.sampleRate)
            lastLevel = features.rms
            let p = vadModel.probability(frame: frame)
            let speechState = vadGate.process(
                probability: p,
                dspPassed: features.passesNoiseGate,
                frameMs: frameMs
            )
            let isSpeech = speechState == .speech
            if isSpeech, state == .listening { state = .inConversation }
            if let event = segmenter.process(isSpeech: isSpeech, frame: frame, frameMs: frameMs) {
                switch event {
                case .opened:
                    state = .inConversation
                case .closed(let seg):
                    onConversationClosed?(seg)
                    state = .listening
                case .discarded:
                    state = .listening
                }
            }
        }
    }
}
