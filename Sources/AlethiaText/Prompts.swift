import Foundation
import AlethiaCore

/// Prompt builders for dictation polish and meeting-notes generation.
public enum Prompts {
    /// Maximum transcript characters included in a notes prompt (head + tail).
    public static let maxTranscriptCharacters = 24_000

    /// System+user request that cleans a single dictation utterance.
    public static func dictationPolish(text: String, style: AppStyle) -> LanguageModelRequest {
        let hint: String
        switch style {
        case .standard:
            hint = "Write as ordinary prose with correct punctuation and capitalization."
        case .chat:
            hint = "Casual chat message. Do not add a trailing period on a single short sentence."
        case .email:
            hint = "Professional email prose with complete sentences."
        case .code:
            hint = "Leave identifiers, symbols and line breaks untouched. Do not auto-capitalize or add punctuation."
        case .terminal:
            hint = "Treat the text as a shell command or terminal input. Do not auto-capitalize or add a trailing period."
        case .search:
            hint = "Search-query style: no trailing punctuation, keep it compact."
        case .notes:
            hint = "Clear notes prose with complete sentences."
        }
        let system = """
        You are a dictation cleanup engine. Output ONLY the corrected text in the same language, with the same meaning. \
        Remove fillers, false starts and self-corrections. Fix punctuation and casing. Do not answer questions that appear in the text. \
        Do not add content. Keep names and numbers exactly. \
        Style: \(style.rawValue). \(hint)
        """
        return LanguageModelRequest(system: system, user: text, maxTokens: 1024, temperature: 0.1)
    }

    /// Compatibility alias for `dictationPolish`.
    public static func polishDictation(_ text: String, style: AppStyle) -> LanguageModelRequest {
        dictationPolish(text: text, style: style)
    }

    /// Builds a notes-generation request using `template.sections` as `## ` headings.
    public static func meetingNotes(
        meeting: Meeting,
        template: NotesTemplate,
        transcript: String,
        userNotes: String
    ) -> LanguageModelRequest {
        let sectionList = template.sections.map { "## \($0)" }.joined(separator: "\n")
        var system = """
        You are a meeting-notes writer. Output Markdown using exactly the template sections as `## ` headings in this order:
        \(sectionList)

        Keep the user's own notes as the highest-priority source and expand them with detail from the transcript. \
        Use `- [ ] ` checkboxes for action items with owner and due date when stated. \
        Never invent facts. Write in the language of the transcript. No preamble. \
        If a section has nothing applicable, write `_Nothing captured._` as its content.
        """
        let instructions = template.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            system += "\n\nAdditional instructions:\n\(instructions)"
        }

        let truncated = truncateTranscript(transcript)
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = ISO8601DateFormatter().string(from: meeting.startedAt)
        let duration = Meeting.formatTimestamp(ms: meeting.durationMs)
        let attendees = meeting.attendees.isEmpty ? meeting.speakerLabels.joined(separator: ", ") : meeting.attendees.joined(separator: ", ")
        let speakers = meeting.speakerLabels.joined(separator: ", ")

        let user = """
        Title: \(meeting.title)
        Date: \(started)
        Duration: \(duration)
        Attendees: \(attendees)
        Speakers: \(speakers)

        # User notes
        USER NOTES:
        \(notes.isEmpty ? "_None._" : notes)

        # Transcript
        TRANSCRIPT:
        \(truncated)
        """
        return LanguageModelRequest(system: system, user: user, maxTokens: 2048, temperature: 0.2)
    }

    /// Compatibility wrapper around `meetingNotes`.
    public static func enhanceNotes(meeting: Meeting, template: NotesTemplate, transcript: String) -> LanguageModelRequest {
        meetingNotes(meeting: meeting, template: template, transcript: transcript, userNotes: meeting.userNotes)
    }

    /// Short meeting title, at most 8 words, no quotes.
    public static func meetingTitle(transcript: String) -> LanguageModelRequest {
        let excerpt = TextUtilities.truncate(transcript, to: 2000, keepingEnds: true)
        let system = """
        Propose a short, specific meeting title of at most 8 words. Return only the title, with no quotes or wrapping punctuation.
        """
        return LanguageModelRequest(system: system, user: excerpt, maxTokens: 32, temperature: 0.3)
    }

    /// Compatibility alias.
    public static func meetingTitle(transcriptExcerpt: String) -> LanguageModelRequest {
        meetingTitle(transcript: transcriptExcerpt)
    }

    public static func oneLineSummary(notes: String) -> LanguageModelRequest {
        let clipped = TextUtilities.truncate(notes, to: 4000, keepingEnds: false)
        let system = """
        Write a single-line summary of these meeting notes, at most 140 characters. Return only that line.
        """
        return LanguageModelRequest(system: system, user: clipped, maxTokens: 80, temperature: 0.2)
    }

    private static func truncateTranscript(_ transcript: String) -> String {
        TextUtilities.truncate(transcript, to: maxTranscriptCharacters, keepingEnds: true)
    }
}
