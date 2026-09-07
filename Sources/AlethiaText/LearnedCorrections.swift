import Foundation

/// A proposed personal-dictionary pair learned from a user edit.
public struct CorrectionCandidate: Sendable, Equatable {
    public var spoken: String
    public var written: String

    public init(spoken: String, written: String) {
        self.spoken = spoken
        self.written = written
    }
}

/// Compares inserted dictation with the user's subsequent edit and proposes short substitutions.
public enum LearnedCorrectionDetector: Sendable {
    /// Returns single- to three-token substitutions. Ignores punctuation-only edits, sentence-start
    /// recasing, and rewrites where either side of a hunk is longer than 3 tokens.
    public static func candidates(inserted: String, edited: String) -> [CorrectionCandidate] {
        let a = words(inserted)
        let b = words(edited)
        if a.isEmpty && b.isEmpty { return [] }

        if a.map({ $0.lowercased() }) == b.map({ $0.lowercased() }) {
            if a.count == b.count {
                var onlyStartCase = true
                for i in 0..<a.count {
                    if a[i] == b[i] { continue }
                    if i == 0 && a[i].lowercased() == b[i].lowercased() { continue }
                    onlyStartCase = false
                    break
                }
                if onlyStartCase { return [] }
            }
        }

        let hunks = diffHunks(a, b)
        var out: [CorrectionCandidate] = []
        for hunk in hunks {
            if hunk.deleted.isEmpty || hunk.inserted.isEmpty { continue }
            if hunk.deleted.count > 3 || hunk.inserted.count > 3 { continue }
            if hunk.aStart == 0, hunk.deleted.count == 1, hunk.inserted.count == 1,
               hunk.deleted[0].lowercased() == hunk.inserted[0].lowercased() {
                continue
            }
            out.append(CorrectionCandidate(
                spoken: hunk.deleted.joined(separator: " "),
                written: hunk.inserted.joined(separator: " ")
            ))
        }
        return out
    }

    private static func words(_ string: String) -> [String] {
        var result: [String] = []
        var current = ""
        for c in string {
            if c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" {
                current.append(c)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private struct Hunk {
        var aStart: Int
        var deleted: [String]
        var inserted: [String]
    }

    private static func diffHunks(_ a: [String], _ b: [String]) -> [Hunk] {
        let matches = lcsMatches(a, b)
        var hunks: [Hunk] = []
        var i = 0
        var j = 0
        var m = 0
        while i < a.count || j < b.count {
            let nextA = m < matches.count ? matches[m].0 : a.count
            let nextB = m < matches.count ? matches[m].1 : b.count
            if i < nextA || j < nextB {
                hunks.append(Hunk(
                    aStart: i,
                    deleted: Array(a[i..<nextA]),
                    inserted: Array(b[j..<nextB])
                ))
                i = nextA
                j = nextB
            }
            if m < matches.count {
                i += 1
                j += 1
                m += 1
            }
        }
        return hunks
    }

    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        if n == 0 || m == 0 { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }
}
