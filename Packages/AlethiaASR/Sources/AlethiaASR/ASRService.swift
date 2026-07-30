import Foundation
import AlethiaCore

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

public protocol SpeechRecognizing: Sendable {
    func transcribe(pcm: [Float], sampleRate: Double) async throws -> [TranscriptSegment]
}

/// Development stub. Replace with whisper.cpp Metal/CoreML bridge.
public struct WhisperStubRecognizer: SpeechRecognizing {
    public init() {}

    public func transcribe(pcm: [Float], sampleRate: Double) async throws -> [TranscriptSegment] {
        let durationMs = Int((Double(pcm.count) / sampleRate) * 1000)
        guard durationMs > 200 else { return [] }
        return [
            TranscriptSegment(
                startMs: 0,
                endMs: durationMs,
                text: "[local whisper pending — install models via Scripts/download-models.sh]"
            )
        ]
    }
}

public final class ASRService: Sendable {
    private let recognizer: any SpeechRecognizing

    public init(recognizer: any SpeechRecognizing = WhisperStubRecognizer()) {
        self.recognizer = recognizer
    }

    public func transcribe(pcm: [Float], sampleRate: Double = 16_000) async throws -> [TranscriptSegment] {
        try await recognizer.transcribe(pcm: pcm, sampleRate: sampleRate)
    }
}
