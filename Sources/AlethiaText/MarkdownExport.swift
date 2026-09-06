import Foundation
import AlethiaCore

/// Markdown export helpers for meetings and dictation history.
public enum MarkdownExport {
    public static func meeting(_ meeting: Meeting, includeTranscript: Bool = true, includeTimestamps: Bool = true) -> String {
        var lines: [String] = []
        lines.append("# \(meeting.title)")
        lines.append("")

        let started = Self.dateTime.string(from: meeting.startedAt)
        lines.append("- Started: \(started)")
        if meeting.durationMs > 0 {
            lines.append("- Duration: \(Meeting.formatTimestamp(ms: meeting.durationMs))")
        }
        if !meeting.attendees.isEmpty {
            lines.append("- Attendees: \(meeting.attendees.joined(separator: ", "))")
        }
        if let summary = meeting.summary, !summary.isEmpty {
            lines.append("- Summary: \(summary)")
        }

        let userNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userNotes.isEmpty {
            lines.append("")
            lines.append("## Your Notes")
            lines.append("")
            lines.append(userNotes)
        }

        if let notes = meeting.enhancedNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
        }

        if includeTranscript, !meeting.utterances.isEmpty {
            lines.append("")
            lines.append("## Transcript")
            lines.append("")
            lines.append(meeting.transcriptText(includeTimestamps: includeTimestamps))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func dictations(_ dictations: [Dictation]) -> String {
        var lines: [String] = ["# Dictations", ""]
        if dictations.isEmpty {
            lines.append("_No dictations._")
            lines.append("")
            return lines.joined(separator: "\n")
        }
        for d in dictations {
            lines.append("## \(dateTime.string(from: d.createdAt))")
            if let app = d.targetAppName, !app.isEmpty {
                lines.append("")
                lines.append("*\(app)*")
            }
            lines.append("")
            lines.append(d.displayText)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
