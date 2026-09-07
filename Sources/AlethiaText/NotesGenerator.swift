import Foundation
import AlethiaCore

/// Offline or model-produced meeting notes plus a one-line summary.
public struct GeneratedNotes: Sendable, Equatable {
    public var markdown: String
    /// One line, at most 160 characters.
    public var summary: String
    public var suggestedTitle: String?
    /// Provider id, or `"local-heuristics"`.
    public var producedBy: String

    public init(markdown: String, summary: String, suggestedTitle: String? = nil, producedBy: String) {
        self.markdown = markdown
        self.summary = summary
        self.suggestedTitle = suggestedTitle
        self.producedBy = producedBy
    }
}

/// Fully offline, deterministic extractive notes from a transcript.
public struct HeuristicNotesSummarizer: Sendable {
    private let engine = HeuristicNotesGenerator()

    public init() {}

    public func summarize(meeting: Meeting, template: NotesTemplate) -> GeneratedNotes {
        let markdown = engine.generate(meeting: meeting, template: template)
        let summary = String(engine.summaryLine(for: meeting).prefix(160))
        return GeneratedNotes(
            markdown: markdown,
            summary: summary,
            suggestedTitle: nil,
            producedBy: "local-heuristics"
        )
    }
}

/// Chooses a language model when available, otherwise falls back to heuristics.
public struct NotesGenerator: Sendable {
    private let provider: (any LanguageModelProvider)?
    private let heuristics = HeuristicNotesSummarizer()

    public init(provider: (any LanguageModelProvider)?) {
        self.provider = provider
    }

    public func generate(meeting: Meeting, template: NotesTemplate) async -> GeneratedNotes {
        if let provider {
            let available = await provider.isAvailable()
            if available {
                do {
                    let transcript = meeting.transcriptText()
                    let request = Prompts.meetingNotes(
                        meeting: meeting,
                        template: template,
                        transcript: transcript,
                        userNotes: meeting.userNotes
                    )
                    let raw = try await provider.complete(request)
                    let markdown = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if headingCoverage(markdown, sections: template.sections) {
                        return GeneratedNotes(
                            markdown: markdown,
                            summary: Self.deriveSummary(from: markdown, fallbackMeeting: meeting),
                            suggestedTitle: nil,
                            producedBy: provider.id
                        )
                    }
                } catch {
                    // Fall back to heuristics.
                }
            }
        }
        return heuristics.summarize(meeting: meeting, template: template)
    }

    /// First non-heading, non-empty line, stripped of markdown, at most 160 characters.
    public static func deriveSummary(from markdown: String, fallbackMeeting: Meeting? = nil) -> String {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") { continue }
            if t.hasPrefix("_") && t.hasSuffix("_") { continue }
            if t.hasPrefix("- [ ]") { t = String(t.dropFirst(5)) }
            else if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }
            t = t.replacingOccurrences(of: "**", with: "")
            t = t.replacingOccurrences(of: "*", with: "")
            t = t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.count <= 160 { return t }
            return String(t.prefix(157)) + "…"
        }
        if let meeting = fallbackMeeting {
            return String(HeuristicNotesGenerator().summaryLine(for: meeting).prefix(160))
        }
        return ""
    }

    private func headingCoverage(_ markdown: String, sections: [String]) -> Bool {
        guard !sections.isEmpty else { return true }
        let lower = markdown.lowercased()
        let hits = sections.filter { lower.contains("## \($0.lowercased())") }
        return hits.count * 2 >= sections.count
    }
}
