import Foundation

/// Full-text search result across meetings, notes, transcripts and dictations.
public struct SearchHit: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case meetingTitle
        case meetingNotes
        case utterance
        case dictation
    }

    public let id: UUID
    public var kind: Kind
    /// Meeting this hit belongs to (nil for dictations).
    public var meetingID: UUID?
    public var title: String
    public var snippet: String
    public var createdAt: Date
    /// Start offset in the recording for utterance hits.
    public var startMs: Int?

    public init(id: UUID, kind: Kind, meetingID: UUID?, title: String, snippet: String, createdAt: Date, startMs: Int? = nil) {
        self.id = id
        self.kind = kind
        self.meetingID = meetingID
        self.title = title
        self.snippet = snippet
        self.createdAt = createdAt
        self.startMs = startMs
    }
}
