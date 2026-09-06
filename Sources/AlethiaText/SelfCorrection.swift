import Foundation

/// Resolves spoken self-corrections such as "Tuesday, no, Wednesday".
enum SelfCorrection {
    struct Outcome {
        var tokens: [Token]
        var changed: Bool
        var wasScratched: Bool
    }

    private enum Kind {
        case restatement
        case scratch
        case actually
        case no
        case sorry
    }

    private struct Marker {
        var words: [String]
        var kind: Kind
        var requiresTrailingComma: Bool = false
    }

    // Longest first.
    private static let markers: [Marker] = [
        Marker(words: ["or", "rather"], kind: .restatement),
        Marker(words: ["make", "that"], kind: .restatement),
        Marker(words: ["no", "wait"], kind: .restatement),
        Marker(words: ["wait", "no"], kind: .restatement),
        Marker(words: ["let", "me", "rephrase"], kind: .scratch),
        Marker(words: ["scratch", "that"], kind: .scratch),
        Marker(words: ["strike", "that"], kind: .scratch),
        Marker(words: ["delete", "that"], kind: .scratch),
        Marker(words: ["undo", "that"], kind: .scratch),
        Marker(words: ["never", "mind", "that"], kind: .scratch),
        Marker(words: ["no", "not"], kind: .restatement),
        Marker(words: ["i", "meant"], kind: .restatement),
        Marker(words: ["i", "mean"], kind: .restatement),
        Marker(words: ["no", "no"], kind: .restatement),
        Marker(words: ["correction"], kind: .scratch),
        Marker(words: ["actually"], kind: .actually),
        Marker(words: ["sorry"], kind: .sorry),
        Marker(words: ["rather"], kind: .restatement),
        Marker(words: ["wait"], kind: .restatement, requiresTrailingComma: true),
        Marker(words: ["no"], kind: .no),
    ]

    static func apply(_ tokens: [Token]) -> Outcome {
        var tokens = tokens
        var changed = false
        var scratched = false
        var guardCount = 0
        while guardCount < 8 {
            guardCount += 1
            if let step = applyOnce(tokens) {
                tokens = step.tokens
                changed = true
                if step.wasScratched { scratched = true }
            } else {
                break
            }
        }
        let empty = Tokenizer.detokenize(tokens).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Outcome(
            tokens: tokens,
            changed: changed,
            wasScratched: scratched || (empty && changed && tokens.filter(\.isWord).isEmpty)
        )
    }

    private static func applyOnce(_ tokens: [Token]) -> Outcome? {
        var i = 0
        while i < tokens.count {
            if tokens[i].frozen || tokens[i].isNewline {
                i += 1
                continue
            }
            for marker in markers {
                guard matches(tokens, at: i, marker: marker) else { continue }
                if let outcome = tryApply(tokens, markerStart: i, marker: marker) {
                    return outcome
                }
            }
            i += 1
        }
        return nil
    }

    private static func matches(_ tokens: [Token], at i: Int, marker: Marker) -> Bool {
        guard i + marker.words.count <= tokens.count else { return false }
        for (offset, word) in marker.words.enumerated() {
            let t = tokens[i + offset]
            if t.isNewline || !t.isWord { return false }
            if t.lower != word { return false }
        }
        if marker.requiresTrailingComma {
            let last = tokens[i + marker.words.count - 1]
            if !last.hasTrailingCommaOrDash { return false }
        }
        return true
    }

    private static func hasCommaBefore(_ tokens: [Token], index i: Int) -> Bool {
        if i == 0 { return false }
        if tokens[i - 1].hasTrailingCommaOrDash { return true }
        if tokens[i - 1].isSeparator { return true }
        if tokens[i].leading.contains(where: { ",-—–".contains($0) }) { return true }
        return false
    }

    private static func hasCommaAfter(_ tokens: [Token], lastIndex: Int) -> Bool {
        if tokens[lastIndex].hasTrailingCommaOrDash { return true }
        if lastIndex + 1 < tokens.count, tokens[lastIndex + 1].isSeparator { return true }
        return false
    }

    private static func isAtInputStart(_ tokens: [Token], index i: Int) -> Bool {
        for j in 0..<i {
            if tokens[j].isWord { return false }
        }
        return true
    }

    private static func tryApply(_ tokens: [Token], markerStart i: Int, marker: Marker) -> Outcome? {
        let length = marker.words.count

        if marker.words == ["rather"] {
            if !hasCommaBefore(tokens, index: i) { return nil }
        }

        if marker.kind == .no {
            // "no" is a marker only when set off by punctuation on both sides.
            guard hasCommaBefore(tokens, index: i), hasCommaAfter(tokens, lastIndex: i) else {
                return nil
            }
        }

        if marker.words == ["i", "mean"] || marker.words == ["i", "meant"] {
            if isAtInputStart(tokens, index: i) { return nil }
        }

        if marker.kind == .actually {
            if !hasCommaBefore(tokens, index: i) { return nil }
        }

        if marker.kind == .sorry {
            if !hasCommaBefore(tokens, index: i) && !hasCommaAfter(tokens, lastIndex: i + length - 1) {
                return nil
            }
        }

        var yIndex = i + length
        if yIndex < tokens.count, tokens[yIndex].isSeparator { yIndex += 1 }

        let yEnd = readReplacementEnd(tokens, from: yIndex)
        let yTokens = Array(tokens[yIndex..<yEnd])
        let yWords = yTokens.filter(\.isWord)

        if marker.kind == .scratch {
            return applyScratch(tokens, markerStart: i, markerLength: length, yStart: yIndex, yEnd: yEnd)
        }

        if yWords.isEmpty { return nil }

        let clauseStart = Tokenizer.lastClauseStart(tokens: tokens, before: i)
        let xTokens = Array(tokens[clauseStart..<i])
        let xWords = xTokens.filter(\.isWord)
        if xWords.isEmpty { return nil }

        if marker.kind == .actually {
            guard let xLast = xWords.last, let yFirst = yWords.first,
                  WordClass.sameClass(xLast.core, yFirst.core) else {
                return nil
            }
        }

        guard let drop = bestDropCount(xWords: xWords, yWords: yWords) else { return nil }

        var head = dropLastWords(xTokens, count: drop)
        if let last = head.indices.last, head[last].hasTrailingCommaOrDash {
            head[last].trailing = head[last].trailing.filter { !",-—–".contains($0) }
        }

        var replacement = yTokens
        if let last = replacement.indices.last {
            // Drop a trailing comma that only existed to set off the correction.
            if replacement[last].hasTrailingCommaOrDash, yEnd < tokens.count {
                replacement[last].trailing = replacement[last].trailing.filter { !",-—–".contains($0) }
            }
        }
        if head.isEmpty {
            replacement[0].spaceBefore = clauseStart > 0 && !tokens[clauseStart - 1].isNewline
            if Tokenizer.isSentenceStart(tokens: tokens, index: clauseStart), replacement[0].isWord {
                replacement[0].core = Tokenizer.capitalizeFirstLetter(replacement[0].core)
            }
        } else {
            replacement[0].spaceBefore = true
        }

        let rest = Array(tokens[yEnd...])
        var rebuilt = Array(tokens[..<clauseStart]) + head + replacement + rest
        if let first = rebuilt.firstIndex(where: { !$0.isNewline }) {
            rebuilt[first].spaceBefore = false
        }
        return Outcome(tokens: rebuilt, changed: true, wasScratched: false)
    }

    private static func bestDropCount(xWords: [Token], yWords: [Token]) -> Int? {
        // Anchor: Y begins with a word that appears in the last 6 words of X.
        if let yFirst = yWords.first {
            let windowStart = max(0, xWords.count - 6)
            var anchor: Int?
            for idx in stride(from: xWords.count - 1, through: windowStart, by: -1) {
                if xWords[idx].lower == yFirst.lower {
                    anchor = idx
                    break
                }
            }
            if let anchor {
                return xWords.count - anchor
            }
        }

        let maxK = min(yWords.count + 1, 6, xWords.count)
        guard maxK >= 1 else { return nil }

        var bestK = 0
        var bestScore = Int.min
        for k in 1...maxK {
            let s = Array(xWords.suffix(k))
            var score = 0

            let minLen = min(s.count, yWords.count)
            var aligned = false
            for offset in 0..<minLen {
                if s[s.count - 1 - offset].lower == yWords[yWords.count - 1 - offset].lower {
                    aligned = true
                    break
                }
            }
            if aligned { score += 3 }

            if let sf = s.first, let yf = yWords.first, WordClass.sameClass(sf.core, yf.core) {
                score += 2
            }
            if s.count == yWords.count { score += 2 }
            if k == 1 && yWords.count == 1 { score += 1 }

            if score > bestScore || (score == bestScore && k < bestK) {
                bestScore = score
                bestK = k
            }
        }
        if bestK == 0 { return nil }
        if bestScore <= 0 { return nil }
        return bestK
    }

    private static func applyScratch(
        _ tokens: [Token],
        markerStart i: Int,
        markerLength length: Int,
        yStart: Int,
        yEnd: Int
    ) -> Outcome {
        var start = Tokenizer.lastClauseStart(tokens: tokens, before: i)
        let wordsBefore = tokens[start..<i].contains(where: { $0.isWord })
        if !wordsBefore, start > 0 {
            start = Tokenizer.lastClauseStart(tokens: tokens, before: start - 1)
        }

        var yTokens = Array(tokens[yStart..<yEnd])
        let rest = Array(tokens[yEnd...])
        if yTokens.isEmpty && rest.filter(\.isWord).isEmpty {
            let head = Array(tokens[..<start])
            let empty = Tokenizer.detokenize(head).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return Outcome(tokens: head, changed: true, wasScratched: empty)
        }
        if !yTokens.isEmpty {
            yTokens[0].spaceBefore = start > 0 && !tokens[start - 1].isNewline
            if yTokens[0].isWord {
                yTokens[0].core = Tokenizer.capitalizeFirstLetter(yTokens[0].core)
            }
        }
        var rebuilt = Array(tokens[..<start]) + yTokens + rest
        if let idx = rebuilt.firstIndex(where: { $0.isWord || $0.isNewline }) {
            rebuilt[idx].spaceBefore = false
            if rebuilt[idx].isWord, Tokenizer.isSentenceStart(tokens: rebuilt, index: idx) {
                rebuilt[idx].core = Tokenizer.capitalizeFirstLetter(rebuilt[idx].core)
            }
        }
        let empty = Tokenizer.detokenize(rebuilt).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Outcome(tokens: rebuilt, changed: true, wasScratched: empty)
    }

    private static func readReplacementEnd(_ tokens: [Token], from start: Int) -> Int {
        var j = start
        while j < tokens.count {
            if tokens[j].isNewline { return j }
            if tokens[j].isSeparator {
                let joined = tokens[j].visible
                if joined.contains(where: { ",.?!;".contains($0) }) { return j }
                j += 1
                continue
            }
            if tokens[j].trailing.contains(where: { ".?!;".contains($0) }) {
                return j + 1
            }
            if tokens[j].trailing.contains(",") {
                return j + 1
            }
            j += 1
        }
        return j
    }

    private static func dropLastWords(_ tokens: [Token], count k: Int) -> [Token] {
        var remaining = k
        var j = tokens.count - 1
        var cut = tokens.count
        while j >= 0 && remaining > 0 {
            if tokens[j].isWord {
                remaining -= 1
                cut = j
            }
            j -= 1
        }
        return Array(tokens.prefix(cut))
    }
}
