import Foundation

func mustCompile(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // Constant patterns only; a failure here is a programmer error.
    try! NSRegularExpression(pattern: pattern, options: options)
}

enum CachedRegex {
    static let multiSpace = mustCompile(#"[ \t\u00a0\u202f]+"#)
    static let spaceBeforePunct = mustCompile(#" +([,.;:?!])"#)
    static let thinkBlock = mustCompile(#"<think>[\s\S]*?</think>"#, options: [.caseInsensitive])
    static let doubleComma = mustCompile(#",\s*,+"#)
    static let leadingComma = mustCompile(#"^(\s*),\s*"#)
    static let doubleSpace = mustCompile(#" {2,}"#)
    static let hereIs = mustCompile(#"^here\s+is\b"#, options: [.caseInsensitive])
    static let surePreamble = mustCompile(#"^sure\b[\s,!:.\-]*"#, options: [.caseInsensitive])
}

extension NSRegularExpression {
    func replace(_ string: String, with template: String) -> String {
        let ns = string as NSString
        return stringByReplacingMatches(
            in: string,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }

    func firstMatch(in string: String) -> NSTextCheckingResult? {
        let ns = string as NSString
        return firstMatch(in: string, options: [], range: NSRange(location: 0, length: ns.length))
    }
}

/// A dictation token: a word with attached punctuation, a punctuation-only run, or a newline.
struct Token: Equatable {
    var core: String
    var leading: String
    var trailing: String
    var spaceBefore: Bool
    var isNewline: Bool
    var frozen: Bool
    var fromCommand: Bool
    var fromDictionary: Bool

    var visible: String { leading + core + trailing }

    var lower: String { core.lowercased() }

    var isWord: Bool {
        !isNewline && core.contains { $0.isLetter || $0.isNumber }
    }

    var endsClause: Bool {
        trailing.contains { ".?!;".contains($0) } || (isNewline)
    }

    var hasTrailingCommaOrDash: Bool {
        trailing.contains { ",-—–".contains($0) }
    }

    var isSeparator: Bool {
        if isNewline { return false }
        if isWord { return false }
        let joined = leading + core + trailing
        return joined.contains { ",-—–;".contains($0) } && !joined.contains { $0.isLetter || $0.isNumber }
    }

    init(
        core: String,
        leading: String = "",
        trailing: String = "",
        spaceBefore: Bool = false,
        isNewline: Bool = false,
        frozen: Bool = false,
        fromCommand: Bool = false,
        fromDictionary: Bool = false
    ) {
        self.core = core
        self.leading = leading
        self.trailing = trailing
        self.spaceBefore = spaceBefore
        self.isNewline = isNewline
        self.frozen = frozen
        self.fromCommand = fromCommand
        self.fromDictionary = fromDictionary
    }
}

enum Tokenizer {
    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
    }

    /// Trim, collapse horizontal whitespace, and pull hanging punctuation back onto the previous word.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "“", with: "\"")
        s = s.replacingOccurrences(of: "”", with: "\"")
        s = s.replacingOccurrences(of: "«", with: "\"")
        s = s.replacingOccurrences(of: "»", with: "\"")
        s = s.replacingOccurrences(of: "‘", with: "'")
        s = s.replacingOccurrences(of: "’", with: "'")
        s = CachedRegex.multiSpace.replace(s, with: " ")
        s = CachedRegex.spaceBeforePunct.replace(s, with: "$1")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokenize(_ string: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(string)
        var i = 0
        var atLineStart = true
        var afterWhitespace = true

        while i < chars.count {
            let c = chars[i]
            if c == "\r" {
                i += 1
                continue
            }
            if c == "\n" {
                var n = 0
                while i < chars.count && chars[i] == "\n" {
                    n += 1
                    i += 1
                }
                tokens.append(Token(core: String(repeating: "\n", count: n), isNewline: true))
                atLineStart = true
                afterWhitespace = true
                continue
            }
            if c.isWhitespace {
                afterWhitespace = true
                i += 1
                continue
            }

            var leading = ""
            while i < chars.count && !chars[i].isWhitespace && chars[i] != "\n" && !isWordChar(chars[i]) && chars[i] != "-" {
                leading.append(chars[i])
                i += 1
            }
            var core = ""
            while i < chars.count {
                let ch = chars[i]
                if isWordChar(ch) {
                    core.append(ch)
                    i += 1
                    continue
                }
                // Keep intra-word hyphens: mm-hmm, well-known.
                if ch == "-", i + 1 < chars.count, isWordChar(chars[i + 1]), !core.isEmpty {
                    core.append(ch)
                    i += 1
                    continue
                }
                break
            }
            var trailing = ""
            while i < chars.count && !chars[i].isWhitespace && chars[i] != "\n" && !isWordChar(chars[i]) {
                trailing.append(chars[i])
                i += 1
            }

            if core.isEmpty && leading.isEmpty && trailing.isEmpty {
                i += 1
                continue
            }

            let spaceBefore = !atLineStart && afterWhitespace
            if core.isEmpty {
                tokens.append(Token(core: leading + trailing, spaceBefore: spaceBefore))
            } else {
                tokens.append(Token(core: core, leading: leading, trailing: trailing, spaceBefore: spaceBefore))
            }
            atLineStart = false
            afterWhitespace = false
        }
        return tokens
    }

    static func detokenize(_ tokens: [Token]) -> String {
        var s = ""
        for t in tokens {
            if t.isNewline {
                s += t.core
                continue
            }
            if t.spaceBefore && !s.isEmpty && !s.hasSuffix("\n") {
                s += " "
            }
            s += t.leading + t.core + t.trailing
        }
        return s
    }

    static func punctuationStrippedLower(_ string: String) -> String {
        tokenize(string)
            .filter { $0.isWord }
            .map(\.lower)
            .joined(separator: " ")
    }

    static func capitalizeFirstLetter(_ string: String) -> String {
        TextUtilities.capitalizingFirstLetter(string)
    }

    static func isSentenceStart(tokens: [Token], index: Int) -> Bool {
        if index <= 0 { return true }
        for j in stride(from: index - 1, through: 0, by: -1) {
            if tokens[j].isNewline { return true }
            if tokens[j].endsClause { return true }
            if tokens[j].isWord { return false }
            if tokens[j].isSeparator { continue }
        }
        return true
    }

    static func lastClauseStart(tokens: [Token], before index: Int) -> Int {
        var start = 0
        let limit = min(index, tokens.count)
        var k = 0
        while k < limit {
            if tokens[k].isNewline || tokens[k].endsClause {
                start = k + 1
            }
            k += 1
        }
        return start
    }

    static func firstWordIndex(_ tokens: [Token]) -> Int? {
        tokens.firstIndex(where: { $0.isWord })
    }

    static func cleanupPunctuationAndSpace(_ string: String) -> String {
        var s = CachedRegex.doubleComma.replace(string, with: ",")
        s = CachedRegex.leadingComma.replace(s, with: "$1")
        s = CachedRegex.doubleSpace.replace(s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WordClass {
    static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    ]

    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
    ]

    static let tlds: Set<String> = [
        "com", "org", "net", "io", "ai", "co", "dev", "edu", "gov", "app", "me", "us", "uk", "de", "fr",
    ]

    static let determiners: Set<String> = [
        "a", "an", "the", "my", "your", "his", "her", "its", "our", "their",
        "this", "that", "these", "those", "one",
    ]

    static func isNumeral(_ word: String) -> Bool {
        let w = word.lowercased()
        if numberWords.contains(w) { return true }
        var sawDigit = false
        for c in w {
            if c.isNumber { sawDigit = true; continue }
            if c.isLetter { continue } // 40k, 45k
            if c == "." || c == "," { continue }
            return false
        }
        return sawDigit
    }

    static func isWeekdayOrMonth(_ word: String) -> Bool {
        let w = word.lowercased()
        return weekdays.contains(w) || months.contains(w)
    }

    static func isCapitalizedProper(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return first.isUppercase && word.count > 1
    }

    static func sameClass(_ a: String, _ b: String) -> Bool {
        if isNumeral(a) && isNumeral(b) { return true }
        if isWeekdayOrMonth(a) && isWeekdayOrMonth(b) { return true }
        if isCapitalizedProper(a) && isCapitalizedProper(b) { return true }
        return false
    }
}
