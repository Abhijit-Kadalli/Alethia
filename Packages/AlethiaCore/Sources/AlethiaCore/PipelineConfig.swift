import Foundation

/// Explicit meeting / dictation recording lifecycle (UI-agnostic).
public enum RecordingState: String, Codable, Sendable {
    case stopped
    case recording
}

public struct PipelineConfig: Codable, Sendable {
    public var sampleRate: Double
    public var frameMs: Double
    public var vadOpenThreshold: Float
    public var vadCloseThreshold: Float
    public var openSpeechMs: Int
    public var closeSilenceMs: Int
    public var minConversationSpeechMs: Int
    public var speakerMatchThreshold: Float
    /// Only surface “Maybe …” identity hints at or above this cosine score.
    public var speakerSuggestionThreshold: Float

    public static let `default` = PipelineConfig(
        sampleRate: 16_000,
        frameMs: 30,
        vadOpenThreshold: 0.50,
        vadCloseThreshold: 0.35,
        openSpeechMs: 150,
        closeSilenceMs: 500,
        minConversationSpeechMs: 1500,
        speakerMatchThreshold: 0.62,
        speakerSuggestionThreshold: 0.80
    )

    public init(
        sampleRate: Double,
        frameMs: Double,
        vadOpenThreshold: Float,
        vadCloseThreshold: Float,
        openSpeechMs: Int,
        closeSilenceMs: Int,
        minConversationSpeechMs: Int,
        speakerMatchThreshold: Float,
        speakerSuggestionThreshold: Float = 0.80
    ) {
        self.sampleRate = sampleRate
        self.frameMs = frameMs
        self.vadOpenThreshold = vadOpenThreshold
        self.vadCloseThreshold = vadCloseThreshold
        self.openSpeechMs = openSpeechMs
        self.closeSilenceMs = closeSilenceMs
        self.minConversationSpeechMs = minConversationSpeechMs
        self.speakerMatchThreshold = speakerMatchThreshold
        self.speakerSuggestionThreshold = speakerSuggestionThreshold
    }
}
