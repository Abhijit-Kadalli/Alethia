import Foundation
import AlethiaCore

/// Optional LLM pass over already rule-formatted dictation, with strict output guardrails.
public struct DictationPolisher: Sendable {
    private let provider: any LanguageModelProvider

    public init(provider: any LanguageModelProvider) {
        self.provider = provider
    }

    /// Runs the model and returns polished text, or `nil` if the output fails guardrails or the call errors.
    public func polish(_ text: String, style: AppStyle) async -> String? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        let available = await provider.isAvailable()
        guard available else { return nil }
        do {
            let raw = try await provider.complete(Prompts.dictationPolish(text: original, style: style))
            var polished = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            polished = Self.stripSurroundingQuotes(polished)
            guard Self.passesGuardrails(original: original, polished: polished) else { return nil }
            return polished
        } catch {
            return nil
        }
    }

    /// True when `polished` looks like a cleaned transcription of `original`, not a model chat reply.
    public static func passesGuardrails(original: String, polished: String) -> Bool {
        var p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        p = stripSurroundingQuotes(p)
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return false }
        if isPreamble(p) && !isPreamble(o) { return false }
        let ratio = Double(p.count) / Double(max(o.count, 1))
        if ratio < 0.4 || ratio > 1.6 { return false }
        if p.contains("\n") && !o.contains("\n") { return false }
        if missingTokenRatio(original: o, polished: p) > 0.40 { return false }
        return true
    }

    static func stripSurroundingQuotes(_ string: String) -> String {
        var t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, let first = t.first, let last = t.last else { return t }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "“" && last == "”") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private static func isPreamble(_ string: String) -> Bool {
        CachedRegex.hereIs.firstMatch(in: string) != nil || CachedRegex.surePreamble.firstMatch(in: string) != nil
    }

    private static func missingTokenRatio(original: String, polished: String) -> Double {
        let orig = Set(alnumTokens(original))
        guard !orig.isEmpty else { return 0 }
        let pol = Set(alnumTokens(polished))
        return Double(orig.subtracting(pol).count) / Double(orig.count)
    }

    private static func alnumTokens(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for c in string {
            if c.isLetter || c.isNumber {
                current.append(c)
            } else if !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }
}
