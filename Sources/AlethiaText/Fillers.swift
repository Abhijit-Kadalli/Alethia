import Foundation

/// Removes spoken fillers, comma-set-off discourse markers, and simple stutters.
enum Fillers {
    static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm",
    ]

    static let stutterProne: Set<String> = [
        "i", "the", "a", "to", "and", "we", "you", "it", "is", "in", "of",
    ]

    private static let discourse: [[String]] = [
        ["you", "know"],
        ["like"],
    ]

    static func apply(_ tokens: [Token]) -> [Token] {
        var tokens = tokens
        let snapshot = tokens
        removeStartFillers(&tokens)
        removeFillerWords(&tokens)
        for phrase in discourse {
            removeCommaSetOff(&tokens, phrase: phrase)
        }
        removeStutters(&tokens)
        dropOrphanCommas(&tokens)
        if tokens != snapshot {
            recapitalizeStart(&tokens)
        }
        return tokens
    }

    /// Light transcript cleanup: um/uh family and stutters only.
    static func applyLight(_ tokens: [Token]) -> [Token] {
        var tokens = tokens
        removeFillerWords(&tokens)
        removeStutters(&tokens)
        dropOrphanCommas(&tokens)
        recapitalizeStart(&tokens)
        return tokens
    }

    static func cleanupString(_ string: String) -> String {
        Tokenizer.cleanupPunctuationAndSpace(string)
    }

    private static let startFillers: Set<String> = ["so", "alright", "allright", "well"]

    private static func removeStartFillers(_ tokens: inout [Token]) {
        guard let start = tokens.firstIndex(where: { $0.isWord }) else { return }
        let w = tokens[start].lower
        if (w == "okay" || w == "ok"),
           start + 1 < tokens.count,
           tokens[start + 1].lower == "so",
           tokens[start + 1].hasTrailingCommaOrDash {
            tokens.removeSubrange(start...(start + 1))
            return
        }
        if startFillers.contains(w), tokens[start].hasTrailingCommaOrDash {
            tokens.remove(at: start)
        }
    }

    private static func removeFillerWords(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            if tokens[i].isWord, fillerWords.contains(tokens[i].lower) {
                absorbSurroundingCommas(&tokens, at: i)
                tokens.remove(at: i)
                continue
            }
            i += 1
        }
    }

    private static func absorbSurroundingCommas(_ tokens: inout [Token], at i: Int) {
        if i > 0, tokens[i - 1].hasTrailingCommaOrDash,
           i + 1 < tokens.count, (tokens[i].hasTrailingCommaOrDash || (i + 1 < tokens.count && tokens[i + 1].isSeparator)) {
            // Keep the previous comma; drop the filler's trailing comma later via cleanup.
            tokens[i].trailing = tokens[i].trailing.filter { $0 != "," }
        }
        if tokens[i].hasTrailingCommaOrDash {
            tokens[i].trailing = tokens[i].trailing.filter { $0 != "," }
        }
    }

    private static func removeCommaSetOff(_ tokens: inout [Token], phrase: [String]) {
        var i = 0
        while i < tokens.count {
            if matches(tokens, at: i, words: phrase),
               isSetOff(tokens, at: i, length: phrase.count) {
                var end = i + phrase.count
                if tokens[end - 1].hasTrailingCommaOrDash {
                    tokens[end - 1].trailing = tokens[end - 1].trailing.filter { $0 != "," }
                }
                if end < tokens.count, tokens[end].isSeparator {
                    end += 1
                }
                tokens.removeSubrange(i..<end)
                continue
            }
            i += 1
        }
    }

    private static func isSetOff(_ tokens: [Token], at i: Int, length: Int) -> Bool {
        let last = i + length - 1
        let commaAfter = tokens[last].hasTrailingCommaOrDash
            || (last + 1 < tokens.count && tokens[last + 1].isSeparator)
        guard commaAfter else { return false }
        if Tokenizer.isSentenceStart(tokens: tokens, index: i) {
            return true
        }
        return i > 0 && (tokens[i - 1].hasTrailingCommaOrDash || tokens[i - 1].isSeparator)
    }

    private static func matches(_ tokens: [Token], at i: Int, words: [String]) -> Bool {
        guard i + words.count <= tokens.count else { return false }
        for (offset, word) in words.enumerated() {
            if !tokens[i + offset].isWord || tokens[i + offset].lower != word { return false }
        }
        return true
    }

    private static func removeStutters(_ tokens: inout [Token]) {
        var i = 1
        while i < tokens.count {
            if tokens[i].isWord, tokens[i - 1].isWord,
               tokens[i].lower == tokens[i - 1].lower,
               stutterProne.contains(tokens[i].lower) {
                tokens.remove(at: i)
                continue
            }
            i += 1
        }
    }

    private static func recapitalizeStart(_ tokens: inout [Token]) {
        guard let idx = tokens.firstIndex(where: { $0.isWord }) else { return }
        if Tokenizer.isSentenceStart(tokens: tokens, index: idx), !tokens[idx].frozen, !tokens[idx].fromDictionary {
            tokens[idx].core = Tokenizer.capitalizeFirstLetter(tokens[idx].core)
            tokens[idx].spaceBefore = false
        }
    }

    private static func dropOrphanCommas(_ tokens: inout [Token]) {
        tokens.removeAll { token in
            !token.isNewline && !token.isWord && token.visible.allSatisfy { $0 == "," || $0.isWhitespace }
        }
        if let first = tokens.firstIndex(where: { !$0.isNewline }) {
            tokens[first].spaceBefore = false
            while tokens[first].leading.first == "," {
                tokens[first].leading.removeFirst()
            }
        }
    }
}
