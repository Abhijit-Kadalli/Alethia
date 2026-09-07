import Foundation

/// Light cleanup for meeting transcripts: fillers, stutters, and spacing. Never rewrites meaning.
public enum TranscriptCleaner: Sendable {
    public static func clean(_ text: String) -> String {
        let normalized = Tokenizer.normalize(text)
        guard !normalized.isEmpty else { return "" }
        let tokens = Fillers.applyLight(Tokenizer.tokenize(normalized))
        return Fillers.cleanupString(Tokenizer.detokenize(tokens))
    }
}
