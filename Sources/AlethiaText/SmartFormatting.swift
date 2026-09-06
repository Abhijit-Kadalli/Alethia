import Foundation

/// Punctuation, spacing, sentence case, and preceding-text awareness.
enum SmartFormatting {
    private static let capIContractions = mustCompile(#"\bi['’](m|ll|ve|d|re)\b"#, options: [.caseInsensitive])
    private static let repeatedPunct = mustCompile(#"([.?!])\1+"#)
    private static let repeatedComma = mustCompile(#",{2,}"#)

    struct Outcome {
        var text: String
        var stages: [String]
        var firstWordFromDictionary: Bool
    }

    static func apply(
        _ text: String,
        style: AppStyle,
        appAware: Bool,
        precedingText: String?,
        firstWordFromDictionary: Bool,
        english: Bool
    ) -> Outcome {
        var stages: [String] = []
        var s = text
        let effectiveStyle = appAware ? style : .standard

        if english {
            var tokens = Tokenizer.tokenize(s)
            let number = NumberFormatting.apply(tokens)
            if number.changed {
                stages.append(contentsOf: number.stages)
                tokens = number.tokens
                s = Tokenizer.detokenize(tokens)
            }
        }

        let beforePunct = s
        s = protectEllipsis(s) { body in
            var t = repeatedPunct.replace(body, with: "$1")
            t = repeatedComma.replace(t, with: ",")
            return t
        }
        s = fixSpacing(s)
        if s != beforePunct { stages.append("punctuation") }

        let skipCaps = effectiveStyle == .code || effectiveStyle == .terminal
        if !skipCaps {
            let beforeCap = s
            s = capIContractions.replace(s, with: "I'$1")
            s = capitalizeStandaloneI(s)
            let midSentence = isMidSentence(precedingText)
            s = capitalizeSentences(s, skipFirst: midSentence && !firstWordFromDictionary)
            if firstWordFromDictionary || isPronounI(firstWord(s)) {
                // keep
            } else if midSentence {
                s = lowercasingFirstLetterUnlessI(s)
            }
            if s != beforeCap { stages.append("capitalization") }
        }

        s = s.trimmingCharacters(in: .whitespaces)
        let beforeStyle = s
        s = applyTrailingPunctuation(s, style: effectiveStyle, precedingText: precedingText)
        if appAware, effectiveStyle != .standard {
            if !stages.contains("app-style") { stages.append("app-style") }
            let tag = "style:\(effectiveStyle.rawValue)"
            if !stages.contains(tag) { stages.append(tag) }
        } else if s != beforeStyle, !stages.contains("punctuation") {
            stages.append("punctuation")
        }

        s = applyPrecedingSpace(s, precedingText: precedingText)
        return Outcome(text: s, stages: stages, firstWordFromDictionary: firstWordFromDictionary)
    }

    static func styleAdjusted(before: String, after: String, style: AppStyle) -> Bool {
        before != after && style != .standard
    }

    static func applyPrecedingOnly(_ text: String, precedingText: String?, firstWordFromDictionary: Bool, style: AppStyle) -> String {
        var s = text
        if isMidSentence(precedingText), !firstWordFromDictionary, !isPronounI(firstWord(s)) {
            s = lowercasingFirstLetterUnlessI(s)
        } else if precedingText == nil || precedingText?.isEmpty == true || endsSentence(precedingText) {
            if style != .code && style != .terminal {
                s = TextUtilities.capitalizingFirstLetter(s)
            }
        }
        return applyPrecedingSpace(s, precedingText: precedingText)
    }

    private static func firstWord(_ text: String) -> String {
        TextUtilities.words(in: text).first ?? ""
    }

    private static func isPronounI(_ word: String) -> Bool {
        let w = word
        return w == "I" || w.hasPrefix("I'") || w.hasPrefix("I’m")
    }

    private static func isMidSentence(_ preceding: String?) -> Bool {
        guard let p = preceding, let last = p.trimmingCharacters(in: .whitespaces).last else {
            return false
        }
        return last.isLetter || last.isNumber || last == ","
    }

    private static func endsSentence(_ preceding: String?) -> Bool {
        guard let p = preceding else { return true }
        if p.isEmpty { return true }
        guard let last = p.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return last == "." || last == "!" || last == "?" || last == "\n"
    }

    private static func applyPrecedingSpace(_ text: String, precedingText: String?) -> String {
        guard let p = precedingText, !p.isEmpty else { return text }
        guard let last = p.last else { return text }
        if last.isWhitespace || last == "\n" { return text }
        if "([{\"'“‘".contains(last) { return text }
        if text.isEmpty { return text }
        if text.hasPrefix(" ") || text.hasPrefix("\n") { return text }
        return " " + text
    }

    private static func lowercasingFirstLetterUnlessI(_ s: String) -> String {
        guard let first = s.first, first.isLetter, first.isUppercase else { return s }
        let word = firstWord(s)
        if isPronounI(word) { return s }
        return String(first).lowercased() + s.dropFirst()
    }

    private static func capitalizeStandaloneI(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if (c == "i" || c == "I"), isWordBoundary(chars, i - 1), isWordBoundary(chars, i + 1) || isContractionBoundary(chars, i + 1) {
                if i + 1 < chars.count, chars[i + 1] == "'" || chars[i + 1] == "’" {
                    out.append("I")
                    i += 1
                    continue
                }
                out.append("I")
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func isWordBoundary(_ chars: [Character], _ i: Int) -> Bool {
        if i < 0 || i >= chars.count { return true }
        let c = chars[i]
        return !c.isLetter && !c.isNumber
    }

    private static func isContractionBoundary(_ chars: [Character], _ i: Int) -> Bool {
        if i < 0 || i >= chars.count { return true }
        return chars[i] == "'" || chars[i] == "’"
    }

    private static func protectEllipsis(_ text: String, _ body: (String) -> String) -> String {
        let sentinel = "\u{F8FF}ELLIPSIS\u{F8FF}"
        var s = text.replacingOccurrences(of: "...", with: sentinel)
        s = s.replacingOccurrences(of: "…", with: sentinel)
        s = body(s)
        return s.replacingOccurrences(of: sentinel, with: "…")
    }

    private static func fixSpacing(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if ",.;:?!".contains(c) {
                while out.last == " " { out.removeLast() }
                out.append(c)
                if i + 1 < chars.count {
                    let n = chars[i + 1]
                    if n != " " && n != "\n" && !")}]\"".contains(n) {
                        let addSpace: Bool
                        switch c {
                        case ".":
                            // Sentence break before a new capital; keep domains, emails, decimals glued.
                            addSpace = n.isUppercase
                        case ",":
                            addSpace = n.isLetter || n == "'" || n == "\"" || n == "("
                        case ":":
                            addSpace = n.isLetter || n == "'" || n == "\"" || n == "("
                        default:
                            addSpace = n.isLetter || n.isNumber || n == "'" || n == "\"" || n == "("
                        }
                        if addSpace { out.append(" ") }
                    }
                }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        out = CachedRegex.doubleSpace.replace(out, with: " ")
        return out
    }

    private static func capitalizeSentences(_ text: String, skipFirst: Bool) -> String {
        var out = ""
        var capNext = !skipFirst
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if capNext && c.isLetter {
                out.append(contentsOf: String(c).uppercased())
                capNext = false
                i += 1
                continue
            }
            out.append(c)
            if c == "?" || c == "!" || c == "\n" {
                capNext = true
            } else if c == "." {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if next == nil || next!.isWhitespace || next!.isUppercase {
                    capNext = true
                }
            } else if !c.isWhitespace {
                capNext = false
            }
            i += 1
        }
        return out
    }

    private static func applyTrailingPunctuation(_ text: String, style: AppStyle, precedingText: String?) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }

        switch style {
        case .code, .terminal, .search:
            if style == .search {
                t = t.replacingOccurrences(of: "\n", with: " ")
                t = CachedRegex.doubleSpace.replace(t, with: " ").trimmingCharacters(in: .whitespaces)
                while let last = t.last, ",.;:?!".contains(last) {
                    t.removeLast()
                }
            }
            return t
        case .chat:
            if shouldAddPeriod(t, precedingText: precedingText) {
                t += "."
            }
            if isSingleSentence(t), t.hasSuffix(".") {
                t.removeLast()
            }
            return t
        case .standard, .email, .notes:
            if shouldAddPeriod(t, precedingText: precedingText) {
                t += "."
            }
            return t
        }
    }

    private static func shouldAddPeriod(_ text: String, precedingText: String?) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") { return false }
        if isMidSentence(precedingText) { return false }
        guard let last = t.last, last.isLetter || last.isNumber else { return false }
        let words = t.split { $0.isWhitespace || $0.isNewline }
        return words.count >= 3
    }

    private static func isSingleSentence(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        var terminals = 0
        let chars = Array(t)
        for (idx, c) in chars.enumerated() {
            if c == "." || c == "?" || c == "!" {
                let nextLetter: Bool
                if idx + 1 < chars.count {
                    nextLetter = chars[(idx + 1)...].contains(where: { $0.isLetter })
                } else {
                    nextLetter = false
                }
                if nextLetter {
                    terminals += 1
                } else {
                    terminals += 1
                }
            }
        }
        // ≥ 2 sentences means there is an internal terminator before the end.
        let internalTerminators = terminals - (t.last == "." || t.last == "?" || t.last == "!" ? 1 : 0)
        return internalTerminators < 1
    }
}
