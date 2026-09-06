import Foundation

/// A personal dictionary entry: how a spoken form should be written.
///
/// Examples: `"alethia" → "Alethia"`, `"k eight s" → "k8s"`, `"my email" → snippet`.
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Added by the user in Settings.
        case user
        /// Learned from an edit the user made to a dictation and confirmed.
        case learned
    }

    public let id: UUID
    /// What the recognizer tends to produce (matched case-insensitively on word boundaries).
    public var spoken: String
    /// What should be written instead.
    public var written: String
    public var origin: Origin
    public var createdAt: Date
    /// How many times this replacement fired.
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        spoken: String,
        written: String,
        origin: Origin = .user,
        createdAt: Date = Date(),
        useCount: Int = 0
    ) {
        self.id = id
        self.spoken = spoken
        self.written = written
        self.origin = origin
        self.createdAt = createdAt
        self.useCount = useCount
    }
}

/// A spoken trigger phrase that expands to longer text.
///
/// Example: saying "insert my signature" inserts a multi-line signature block.
public struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// Trigger phrase, matched as a whole (case-insensitive), optionally prefixed with "insert".
    public var trigger: String
    public var expansion: String
    public var createdAt: Date
    public var useCount: Int

    public init(id: UUID = UUID(), trigger: String, expansion: String, createdAt: Date = Date(), useCount: Int = 0) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.createdAt = createdAt
        self.useCount = useCount
    }
}
