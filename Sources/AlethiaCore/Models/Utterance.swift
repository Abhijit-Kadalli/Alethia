import Foundation

/// A single recognized word with timing relative to the start of the recording.
public struct TimedWord: Codable, Hashable, Sendable {
    public var text: String
    public var startMs: Int
    public var endMs: Int
    /// Recognizer confidence in 0…1 when available.
    public var confidence: Float?

    public init(text: String, startMs: Int, endMs: Int, confidence: Float? = nil) {
        self.text = text
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.confidence = confidence
    }
}

/// A speaker-attributed span of transcript.
public struct Utterance: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var meetingID: UUID
    /// Persistent speaker identity, when matched or labeled.
    public var speakerID: UUID?
    /// Display label — a name once labeled, otherwise `Speaker 1`, `Speaker 2`, … or `You`.
    public var speakerLabel: String
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var words: [TimedWord]
    /// True when the audio for this span came predominantly from the local microphone
    /// (i.e. the user was speaking) rather than from system audio.
    public var isLocalSpeaker: Bool?
    /// Cosine similarity to the matched gallery speaker (0…1) when a suggestion exists.
    public var matchConfidence: Float?
    /// Gallery name suggested for this speaker when confidence is high but not yet accepted.
    public var suggestedSpeakerName: String?

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        speakerID: UUID? = nil,
        speakerLabel: String,
        startMs: Int,
        endMs: Int,
        text: String,
        words: [TimedWord] = [],
        isLocalSpeaker: Bool? = nil,
        matchConfidence: Float? = nil,
        suggestedSpeakerName: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.text = text
        self.words = words
        self.isLocalSpeaker = isLocalSpeaker
        self.matchConfidence = matchConfidence
        self.suggestedSpeakerName = suggestedSpeakerName
    }

    public var durationMs: Int { endMs - startMs }
}

/// A recognizer output span before speaker attribution.
public struct TranscriptSegment: Codable, Hashable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var words: [TimedWord]
    public var confidence: Float?

    public init(startMs: Int, endMs: Int, text: String, words: [TimedWord] = [], confidence: Float? = nil) {
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.text = text
        self.words = words
        self.confidence = confidence
    }
}

/// A speaker-homogeneous time range from the diarizer.
public struct SpeakerSegment: Codable, Hashable, Sendable {
    /// Diarizer-local cluster identifier (stable within one meeting only).
    public var clusterID: String
    public var startMs: Int
    public var endMs: Int
    /// Speaker embedding for this cluster when the diarizer exposes one.
    public var embedding: [Float]?

    public init(clusterID: String, startMs: Int, endMs: Int, embedding: [Float]? = nil) {
        self.clusterID = clusterID
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.embedding = embedding
    }
}
