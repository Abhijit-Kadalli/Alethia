import Foundation

/// How a meeting's audio was captured.
public enum CaptureSource: String, Codable, Sendable, CaseIterable {
    /// Microphone only.
    case microphone
    /// Microphone mixed with system audio (calls in Zoom, Meet, Teams, …).
    case microphoneAndSystem

    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .microphoneAndSystem: return "Microphone + system audio"
        }
    }
}

/// Lifecycle of a meeting record.
public enum MeetingStatus: String, Codable, Sendable {
    /// Audio is being captured right now.
    case recording
    /// Recording finished; transcription / diarization / notes are running.
    case processing
    /// Transcript is available.
    case ready
    /// Processing failed; `processingError` explains why. Audio is kept so it can be retried.
    case failed
}

/// A recorded conversation: transcript, the user's own notes, and generated notes.
public struct Meeting: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var source: CaptureSource
    public var status: MeetingStatus
    public var processingError: String?
    /// Relative path under the app support directory (e.g. `Recordings/<id>.wav`).
    public var audioPath: String?
    public var durationMs: Int
    /// BCP-47 language code detected/selected for transcription (e.g. `en`).
    public var language: String?

    /// Notes typed by the user before, during, or after the meeting (Markdown).
    public var userNotes: String
    /// Notes produced by the notes pipeline (Markdown), merging `userNotes` with the transcript.
    public var enhancedNotes: String?
    public var enhancedNotesTemplateID: String?
    public var enhancedAt: Date?
    /// Which provider produced `enhancedNotes` (e.g. `apple-intelligence`, `openai-compatible`, `local-heuristics`).
    public var enhancedBy: String?
    /// One-line summary for lists.
    public var summary: String?

    /// Calendar event this meeting was linked to, if any.
    public var calendarEventID: String?
    public var attendees: [String]

    public var utterances: [Utterance]

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        source: CaptureSource = .microphoneAndSystem,
        status: MeetingStatus = .recording,
        processingError: String? = nil,
        audioPath: String? = nil,
        durationMs: Int = 0,
        language: String? = nil,
        userNotes: String = "",
        enhancedNotes: String? = nil,
        enhancedNotesTemplateID: String? = nil,
        enhancedAt: Date? = nil,
        enhancedBy: String? = nil,
        summary: String? = nil,
        calendarEventID: String? = nil,
        attendees: [String] = [],
        utterances: [Utterance] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.status = status
        self.processingError = processingError
        self.audioPath = audioPath
        self.durationMs = durationMs
        self.language = language
        self.userNotes = userNotes
        self.enhancedNotes = enhancedNotes
        self.enhancedNotesTemplateID = enhancedNotesTemplateID
        self.enhancedAt = enhancedAt
        self.enhancedBy = enhancedBy
        self.summary = summary
        self.calendarEventID = calendarEventID
        self.attendees = attendees
        self.utterances = utterances
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Distinct speaker labels in transcript order.
    public var speakerLabels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in utterances where !seen.contains(u.speakerLabel) {
            seen.insert(u.speakerLabel)
            out.append(u.speakerLabel)
        }
        return out
    }

    /// Plain-text transcript with speaker prefixes, suitable for prompts and export.
    public func transcriptText(includeTimestamps: Bool = false) -> String {
        utterances.map { u in
            let stamp = includeTimestamps ? "[\(Self.formatTimestamp(ms: u.startMs))] " : ""
            return "\(stamp)\(u.speakerLabel): \(u.text)"
        }.joined(separator: "\n")
    }

    public static func formatTimestamp(ms: Int) -> String {
        let total = max(ms, 0) / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    public static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting · \(formatter.string(from: date))"
    }
}
