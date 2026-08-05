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
        source: CaptureSource = .meeting,
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
    case meeting
    case dictation
    case mixed
    /// Legacy rows from always-on ambient; treated like meeting in the UI.
    case ambient
}

public struct TimedWord: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var word: String
    public var startMs: Int
    public var endMs: Int

    public init(id: UUID = UUID(), word: String, startMs: Int, endMs: Int) {
        self.id = id
        self.word = word
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct Utterance: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var speakerID: UUID?
    public var speakerLabel: String
    public var startMs: Int
    public var endMs: Int
    /// Verbatim (what was said).
    public var text: String
    /// Intended / cleaned (what was meant), when available.
    public var intendedText: String?
    /// Per-word timings (verbatim when available).
    public var words: [TimedWord]

    public init(
        id: UUID = UUID(),
        speakerID: UUID? = nil,
        speakerLabel: String = "Speaker 1",
        startMs: Int,
        endMs: Int,
        text: String,
        intendedText: String? = nil,
        words: [TimedWord] = []
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.intendedText = intendedText
        self.words = words
    }

    public func displayText(verbatim: Bool) -> String {
        if verbatim { return text }
        return intendedText?.nilIfEmpty ?? text
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
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
    /// Verbatim transcript when available (hub archive); `text` is what was pasted (intended).
    public var verbatimText: String?
    public var targetBundleID: String?
    public var sessionID: UUID?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        verbatimText: String? = nil,
        targetBundleID: String? = nil,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.verbatimText = verbatimText
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
            return "Microphone access is required for meeting recording and dictation."
        case .accessibilityPermissionDenied:
            return "Enable Alethia in System Settings → Privacy & Security → Accessibility (use ~/Applications/Alethia.app), then Quit and relaunch."
        case .modelMissing(let name):
            return "Required model is missing: \(name). Run Scripts/download-models.sh."
        case .database(let message):
            return "Knowledge store error: \(message)"
        case .audioEngine(let message):
            return "Audio engine error: \(message)"
        }
    }
}
