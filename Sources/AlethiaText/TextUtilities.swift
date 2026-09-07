import Foundation

/// Sentence and word helpers shared by the dictation pipeline and notes generator.
public enum TextUtilities {
    /// Splits `text` into sentences, keeping trailing `.?!` on each sentence.
    public static func sentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        var current = ""
        let chars = Array(trimmed)
        var i = 0
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "vs", "etc", "st", "ave"]

        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if c == "\n" {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { sentences.append(piece) }
                current = ""
                i += 1
                continue
            }
            if c == "." || c == "?" || c == "!" {
                let wordBefore = lastWord(in: current.dropLast())
                let isAbbrev = c == "." && abbreviations.contains(wordBefore.lowercased())
                let next = nextNonSpace(chars, after: i)
                let looksLikeEnd = next == nil || next!.isUppercase || next == "\n"
                    || (c != "." && next != nil)
                if !isAbbrev && (looksLikeEnd || next == nil || !(next!.isLetter || next!.isNumber)) {
                    // Consume following extra terminal punctuation.
                    var j = i + 1
                    while j < chars.count && ".?!".contains(chars[j]) {
                        current.append(chars[j])
                        j += 1
                    }
                    let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty { sentences.append(piece) }
                    current = ""
                    i = j
                    continue
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Whitespace-separated tokens, stripping wrapping punctuation from each.
    public static func words(in text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map { raw in
            var s = String(raw)
            while let first = s.first, !first.isLetter && !first.isNumber && first != "'" {
                s.removeFirst()
            }
            while let last = s.last, !last.isLetter && !last.isNumber && last != "'" {
                s.removeLast()
            }
            return s
        }.filter { !$0.isEmpty }
    }

    public static func capitalizingFirstLetter(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Truncates `s` to `maxChars`. When `keepingEnds` is true, keeps the start and
    /// end with a `[…]` marker in the middle.
    public static func truncate(_ s: String, to maxChars: Int, keepingEnds: Bool) -> String {
        guard maxChars >= 0 else { return "" }
        if s.count <= maxChars { return s }
        if !keepingEnds {
            return String(s.prefix(maxChars))
        }
        let marker = "[…]"
        if maxChars <= marker.count {
            return String(s.prefix(maxChars))
        }
        let budget = maxChars - marker.count
        let head = budget / 2
        let tail = budget - head
        return String(s.prefix(head)) + marker + String(s.suffix(tail))
    }

    private static func lastWord<S: StringProtocol>(in text: S) -> String {
        var word = ""
        for c in text.reversed() {
            if c.isLetter {
                word.insert(c, at: word.startIndex)
            } else if !word.isEmpty {
                break
            }
        }
        return word
    }

    private static func nextNonSpace(_ chars: [Character], after index: Int) -> Character? {
        var j = index + 1
        while j < chars.count {
            if !chars[j].isWhitespace { return chars[j] }
            j += 1
        }
        return nil
    }
}
