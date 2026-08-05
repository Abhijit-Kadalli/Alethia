import Foundation
import AlethiaCore

public protocol SpeechRecognizing: Sendable {
    func transcribe(pcm: [Float], sampleRate: Double) async throws -> [TranscriptSegment]
    func transcribe(pcm: [Float], sampleRate: Double, mode: ASRMode) async throws -> [TranscriptSegment]
}

public extension SpeechRecognizing {
    func transcribe(pcm: [Float], sampleRate: Double, mode: ASRMode) async throws -> [TranscriptSegment] {
        // Default: ignore mode (stubs / legacy).
        try await transcribe(pcm: pcm, sampleRate: sampleRate)
    }
}

public struct TranscriptSegment: Sendable, Hashable {
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// Offline stub used when CrisperWhisper sidecar is not installed.
public struct WhisperStubRecognizer: SpeechRecognizing {
    public init() {}

    public func transcribe(pcm: [Float], sampleRate: Double) async throws -> [TranscriptSegment] {
        let durationMs = Int((Double(pcm.count) / sampleRate) * 1000)
        guard durationMs > 200 else { return [] }
        return [
            TranscriptSegment(
                startMs: 0,
                endMs: durationMs,
                text: "[local crisperwhisper pending — run Scripts/setup-crisperwhisper.sh]"
            )
        ]
    }
}

public final class ASRService: Sendable {
    private let recognizer: any SpeechRecognizing

    public init(recognizer: (any SpeechRecognizing)? = nil) {
        self.recognizer = recognizer ?? ASRFactory.makeDefault()
    }

    public func transcribe(
        pcm: [Float],
        sampleRate: Double = 16_000,
        mode: ASRMode = .intended
    ) async throws -> [TranscriptSegment] {
        try await recognizer.transcribe(pcm: pcm, sampleRate: sampleRate, mode: mode)
    }
}
