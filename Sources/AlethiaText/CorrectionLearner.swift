import Foundation

/// Derives personal-dictionary candidates by comparing inserted text with the user's edit.
public struct CorrectionLearner: Sendable {
    public struct Suggestion: Sendable, Hashable {
        public var spoken: String
        public var written: String

        public init(spoken: String, written: String) {
            self.spoken = spoken
            self.written = written
        }
    }

    public init() {}

    /// Only short substitutions (1–3 words each side, alphabetic-ish) with the same rough position
    /// are returned. Ignores pure punctuation edits and edits where written is empty.
    public func suggestions(inserted: String, edited: String) -> [Suggestion] {
        if inserted == edited { return [] }
        let a = tokenize(inserted)
        let b = tokenize(edited)
        if a.isEmpty && b.isEmpty { return [] }

        let ops = diff(a, b)
        var suggestions: [Suggestion] = []
        var i = 0
        while i < ops.count {
            if case .equal = ops[i] {
                i += 1
                continue
            }
            var deleted: [Word] = []
            var insertedWords: [Word] = []
            var j = i
            while j < ops.count {
                switch ops[j] {
                case .equal:
                    break
                case .delete(let w):
                    deleted.append(w)
                    j += 1
                    continue
                case .insert(let w):
                    insertedWords.append(w)
                    j += 1
                    continue
                }
                break
            }
            i = max(j, i + 1)
            if deleted.isEmpty || insertedWords.isEmpty { continue }
            if deleted.count > 3 || insertedWords.count > 3 { continue }
            let spoken = deleted.map(\.lower).joined(separator: " ")
            let written = insertedWords.map(\.raw).joined(separator: " ")
            if written.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if !isAlphabeticIsh(spoken) || !isAlphabeticIsh(written) { continue }
            suggestions.append(Suggestion(spoken: spoken, written: written))
        }
        return suggestions
    }

    private struct Word {
        var raw: String
        var lower: String
    }

    private enum Op {
        case equal(Word)
        case delete(Word)
        case insert(Word)
    }

    private func tokenize(_ text: String) -> [Word] {
        text.split { $0.isWhitespace || $0.isNewline }.map { raw in
            let stripped = stripWrappingPunct(String(raw))
            let core = stripped.isEmpty ? String(raw) : stripped
            return Word(raw: core, lower: core.lowercased())
        }
    }

    private func stripWrappingPunct(_ s: String) -> String {
        var t = s
        while let first = t.first, !first.isLetter && !first.isNumber && first != "'" {
            t.removeFirst()
        }
        while let last = t.last, !last.isLetter && !last.isNumber && last != "'" {
            t.removeLast()
        }
        return t
    }

    private func isAlphabeticIsh(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter || $0.isNumber }
        return !letters.isEmpty
    }

    private func diff(_ a: [Word], _ b: [Word]) -> [Op] {
        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    if a[i - 1].raw == b[j - 1].raw {
                        dp[i][j] = dp[i - 1][j - 1] + 1
                    } else {
                        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                    }
                }
            }
        }
        var ops: [Op] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1].raw == b[j - 1].raw {
                ops.append(.equal(a[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || dp[i][j - 1] >= dp[max(i - 1, 0)][j] {
                ops.append(.insert(b[j - 1]))
                j -= 1
            } else if i > 0 {
                ops.append(.delete(a[i - 1]))
                i -= 1
            } else {
                break
            }
        }
        return ops.reversed()
    }
}
