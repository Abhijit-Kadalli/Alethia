import Foundation
import AlethiaCore

/// Extractive meeting notes that work with no language model.
public struct HeuristicNotesGenerator: Sendable {
    public init() {}

    public func generate(meeting: Meeting, template: NotesTemplate) -> String {
        var parts: [String] = []
        let userNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userNotes.isEmpty {
            parts.append("## Your Notes\n\n\(userNotes)")
        }

        let scored = scoredSentences(meeting: meeting)
        var used = Set<Int>()

        for section in template.sections {
            let body = fillSection(section, scored: scored, meeting: meeting, used: &used)
            parts.append("## \(section)\n\n\(body)")
        }
        return parts.joined(separator: "\n\n")
    }

    public func summaryLine(for meeting: Meeting) -> String {
        if let existing = meeting.summary, !existing.isEmpty {
            return String(existing.prefix(140))
        }
        let scored = scoredSentences(meeting: meeting)
        let best = scored.sorted { $0.score > $1.score }.first?.text
            ?? meeting.title
        let trimmed = best.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 140 { return trimmed }
        return String(trimmed.prefix(137)) + "…"
    }

    private struct ScoredSentence {
        var text: String
        var speaker: String
        var index: Int
        var score: Double
        var wordCount: Int
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "is", "are",
        "was", "were", "be", "been", "being", "it", "this", "that", "with", "as", "by", "from",
        "we", "you", "i", "they", "he", "she", "them", "our", "your", "their", "not", "if",
        "then", "so", "than", "too", "very", "can", "will", "just", "about", "into", "up",
        "out", "do", "does", "did", "have", "has", "had", "i'm", "we're", "it's", "that's",
    ]

    private func scoredSentences(meeting: Meeting) -> [ScoredSentence] {
        var raw: [(text: String, speaker: String)] = []
        for u in meeting.utterances {
            let chunk = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }
            let pieces = TextUtilities.sentences(in: chunk)
            if pieces.isEmpty {
                raw.append((chunk, u.speakerLabel))
            } else {
                for p in pieces { raw.append((p, u.speakerLabel)) }
            }
        }

        var df: [String: Int] = [:]
        for item in raw {
            for t in Set(contentTerms(item.text)) { df[t, default: 0] += 1 }
        }

        var scored: [ScoredSentence] = []
        for (idx, item) in raw.enumerated() {
            let terms = contentTerms(item.text)
            var tf: [String: Int] = [:]
            for t in terms { tf[t, default: 0] += 1 }
            var score = 0.0
            for (term, count) in tf {
                let rarity = Double(raw.count + 1) / Double((df[term] ?? 0) + 1)
                score += Double(count) * rarity
            }
            let wc = TextUtilities.words(in: item.text).count
            if wc >= 6 && wc <= 35 { score *= 1.4 }
            else if wc < 4 || wc > 50 { score *= 0.6 }
            if item.text.contains(where: { $0.isNumber }) { score *= 1.25 }
            if hasCapitalizedName(item.text) { score *= 1.2 }
            scored.append(ScoredSentence(text: item.text, speaker: item.speaker, index: idx, score: score, wordCount: wc))
        }
        return scored
    }

    private func contentTerms(_ text: String) -> [String] {
        TextUtilities.words(in: text).map { $0.lowercased() }.filter { !Self.stopwords.contains($0) && $0.count > 1 }
    }

    private func hasCapitalizedName(_ text: String) -> Bool {
        let words = TextUtilities.words(in: text)
        for (i, w) in words.enumerated() {
            if i == 0 { continue }
            if let f = w.first, f.isUppercase, w.count > 1 { return true }
        }
        return false
    }

    private func fillSection(
        _ section: String,
        scored: [ScoredSentence],
        meeting: Meeting,
        used: inout Set<Int>
    ) -> String {
        let key = section.lowercased()
        if scored.isEmpty {
            if isAttendees(key) { return attendeesBody(meeting) }
            return "_Nothing captured for this section._"
        }

        if isAttendees(key) { return attendeesBody(meeting) }
        if isSummary(key) {
            return bullets(topChronological(scored, used: &used, count: 5), asQuotes: false)
        }
        if isActions(key) { return actionItems(scored, used: &used) }
        if isDecisions(key) {
            return bullets(matching(scored, used: &used, pattern: Self.decisionPattern, max: 6), asQuotes: false)
        }
        if isQuestions(key) {
            var picked: [ScoredSentence] = []
            for q in scored where q.text.trimmingCharacters(in: .whitespaces).hasSuffix("?") {
                used.insert(q.index)
                picked.append(q)
                if picked.count >= 8 { break }
            }
            return bullets(picked, asQuotes: false)
        }
        if isQuotes(key) {
            let remaining = scored.filter { !used.contains($0.index) }.sorted { $0.score > $1.score }
            let top = Array(remaining.prefix(3))
            for t in top { used.insert(t.index) }
            if top.isEmpty { return "_Nothing captured for this section._" }
            return top.map { "> \"\(stripOuterQuotes($0.text))\" — \($0.speaker)" }.joined(separator: "\n\n")
        }

        let hints = keywords(for: key)
        let remaining = scored.filter { !used.contains($0.index) }
        let ranked = remaining.sorted { a, b in
            let ka = keywordBoost(a.text, hints)
            let kb = keywordBoost(b.text, hints)
            if ka != kb { return ka > kb }
            return a.score > b.score
        }
        let picked = Array(ranked.prefix(6))
        for p in picked { used.insert(p.index) }
        return bullets(picked.sorted { $0.index < $1.index }, asQuotes: false)
    }

    private func isSummary(_ key: String) -> Bool {
        ["summary", "overview", "highlights", "background", "customer context", "goal"].contains(key)
            || key.contains("summary") || key.contains("overview") || key.contains("highlight")
    }

    private func isActions(_ key: String) -> Bool {
        key.contains("action") || key.contains("next step") || key.contains("follow") || key == "today"
    }

    private func isDecisions(_ key: String) -> Bool {
        key.contains("decision")
    }

    private func isQuestions(_ key: String) -> Bool {
        key.contains("question")
    }

    private func isQuotes(_ key: String) -> Bool {
        key.contains("quote")
    }

    private func isAttendees(_ key: String) -> Bool {
        key.contains("attendee")
    }

    private func keywords(for key: String) -> [String] {
        if key.contains("blocker") { return ["blocked", "blocker", "stuck", "waiting"] }
        if key.contains("pain") { return ["problem", "issue", "frustrat", "pain", "slow", "hard"] }
        if key.contains("requirement") { return ["need", "must", "require"] }
        if key.contains("win") { return ["shipped", "launched", "finished", "great", "win"] }
        if key.contains("challenge") || key.contains("concern") { return ["worry", "concern", "risk", "challenge", "hard"] }
        if key.contains("strength") { return ["strong", "strength", "good", "solid"] }
        if key.contains("yesterday") { return ["yesterday", "did", "done", "finished"] }
        return []
    }

    private func keywordBoost(_ text: String, _ keywords: [String]) -> Int {
        guard !keywords.isEmpty else { return 0 }
        let lower = text.lowercased()
        return keywords.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }

    private static let actionPattern = mustCompile(
        #"\b(i'll|i will|we'll|we will|we need to|need to|let's|should|going to|todo|action item|follow up|by (monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|next week|end of))\b"#,
        options: [.caseInsensitive]
    )

    private static let decisionPattern = mustCompile(
        #"\b(decided|we agreed|agreed|let's go with|the plan is|we're going with|final answer)\b"#,
        options: [.caseInsensitive]
    )

    private func matching(_ scored: [ScoredSentence], used: inout Set<Int>, pattern: NSRegularExpression, max: Int) -> [ScoredSentence] {
        var picked: [ScoredSentence] = []
        for s in scored {
            let ns = s.text as NSString
            if pattern.firstMatch(in: s.text, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                used.insert(s.index)
                picked.append(s)
                if picked.count >= max { break }
            }
        }
        return picked
    }

    private func actionItems(_ scored: [ScoredSentence], used: inout Set<Int>) -> String {
        let items = matching(scored, used: &used, pattern: Self.actionPattern, max: 12)
        if items.isEmpty { return "_Nothing captured for this section._" }
        return items.map { s in
            let prefix = (s.speaker == "You") ? "" : "\(s.speaker): "
            return "- [ ] \(prefix)\(stripTrailingPunct(s.text))"
        }.joined(separator: "\n")
    }

    private func topChronological(_ scored: [ScoredSentence], used: inout Set<Int>, count: Int) -> [ScoredSentence] {
        let ranked = scored.sorted { $0.score > $1.score }
        var picked: [ScoredSentence] = []
        for s in ranked {
            if used.contains(s.index) { continue }
            used.insert(s.index)
            picked.append(s)
            if picked.count >= count { break }
        }
        return picked.sorted { $0.index < $1.index }
    }

    private func bullets(_ items: [ScoredSentence], asQuotes: Bool) -> String {
        if items.isEmpty { return "_Nothing captured for this section._" }
        return items.map { "- \(stripTrailingPunct($0.text))" }.joined(separator: "\n")
    }

    private func attendeesBody(_ meeting: Meeting) -> String {
        var names: [String] = []
        var seen = Set<String>()
        for label in meeting.speakerLabels + meeting.attendees {
            let key = label.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            names.append(label)
        }
        if names.isEmpty { return "_Nothing captured for this section._" }
        return names.map { "- \($0)" }.joined(separator: "\n")
    }

    private func stripTrailingPunct(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    private func stripOuterQuotes(_ s: String) -> String {
        var t = stripTrailingPunct(s)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            t.removeFirst()
            t.removeLast()
        }
        return t
    }
}
