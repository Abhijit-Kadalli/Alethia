import Foundation

/// How dictated text reached the target application.
public enum InsertionMethod: String, Codable, Sendable {
    case accessibility
    case paste
    case keystrokes
    /// Text was left on the clipboard because no insertion path worked.
    case clipboardOnly
    /// Aborted because a secure (password) field had focus at insertion time.
    case blockedSecureField
}

/// One completed dictation.
public struct Dictation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var createdAt: Date
    /// Raw recognizer output before any cleanup.
    public var rawText: String
    /// Text after the formatting pipeline — what was inserted.
    public var finalText: String
    /// Text after the user edited it in the correction popover, if they did.
    public var editedText: String?
    public var targetBundleID: String?
    public var targetAppName: String?
    public var durationMs: Int
    public var insertion: InsertionMethod?
    /// Which cleanup stages ran (for diagnostics), e.g. `["fillers", "self-correction", "llm:apple-intelligence"]`.
    public var appliedStages: [String]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        finalText: String,
        editedText: String? = nil,
        targetBundleID: String? = nil,
        targetAppName: String? = nil,
        durationMs: Int = 0,
        insertion: InsertionMethod? = nil,
        appliedStages: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.finalText = finalText
        self.editedText = editedText
        self.targetBundleID = targetBundleID
        self.targetAppName = targetAppName
        self.durationMs = durationMs
        self.insertion = insertion
        self.appliedStages = appliedStages
    }

    /// The best available text: the user's edit if any, otherwise what was inserted.
    public var displayText: String { editedText ?? finalText }

    public var wordCount: Int {
        displayText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
