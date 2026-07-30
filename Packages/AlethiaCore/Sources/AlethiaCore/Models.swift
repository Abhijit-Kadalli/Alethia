import Foundation

public struct ConversationSession: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var source: CaptureSource
    public var utterances: [Utterance]

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        source: CaptureSource = .ambient,
        utterances: [Utterance] = []
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.utterances = utterances
    }
}

public enum CaptureSource: String, Codable, Sendable {
    case ambient
    case dictation
    case mixed
}

public struct Utterance: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var speakerID: UUID?
    public var speakerLabel: String
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(
        id: UUID = UUID(),
        speakerID: UUID? = nil,
        speakerLabel: String = "Speaker 1",
        startMs: Int,
        endMs: Int,
        text: String
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public struct SpeakerProfile: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var displayName: String
    /// 192-dim ECAPA centroid; stored separately in SQLite as blob in production.
    public var embedding: [Float]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        embedding: [Float] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.updatedAt = updatedAt
    }
}

public struct DictationEvent: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var createdAt: Date
    public var text: String
    public var targetBundleID: String?
    public var sessionID: UUID?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        targetBundleID: String? = nil,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.targetBundleID = targetBundleID
        self.sessionID = sessionID
    }
}

public struct KnowledgeHit: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var kind: Kind
    public var title: String
    public var snippet: String
    public var createdAt: Date

    public enum Kind: String, Codable, Sendable {
        case utterance
        case dictation
        case session
    }

    public init(id: UUID, kind: Kind, title: String, snippet: String, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.createdAt = createdAt
    }
}

public enum AlethiaError: Error, LocalizedError, Sendable {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case modelMissing(String)
    case database(String)
    case audioEngine(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required for ambient listening and dictation."
        case .accessibilityPermissionDenied:
            return "Accessibility access is required to type dictated text into other apps."
        case .modelMissing(let name):
            return "Required model is missing: \(name). Run Scripts/download-models.sh."
        case .database(let message):
            return "Knowledge store error: \(message)"
        case .audioEngine(let message):
            return "Audio engine error: \(message)"
        }
    }
}
