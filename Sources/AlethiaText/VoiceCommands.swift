import Foundation

/// Spoken dictation commands: punctuation, newlines, scratch, caps, and glue.
enum VoiceCommands {
    struct Outcome {
        var tokens: [Token]
        var changed: Bool
        var wasScratched: Bool
    }

    private struct CommandResult {
        var nextIndex: Int
        var scratched: Bool
    }

    static func apply(_ tokens: [Token]) -> Outcome {
        var tokens = tokens
        var i = 0
        var changed = false
        var scratched = false
        var quoteOpen = false
        var capsLock = false

        while i < tokens.count {
            if tokens[i].isNewline || tokens[i].frozen {
                if capsLock, tokens[i].isWord {
                    tokens[i].core = tokens[i].core.uppercased()
                    tokens[i].fromCommand = true
                    changed = true
                }
                i += 1
                continue
            }

            if capsLock, tokens[i].isWord,
               !isPhraseStart(tokens, i, ["caps", "lock"]) {
                tokens[i].core = tokens[i].core.uppercased()
                tokens[i].fromCommand = true
                changed = true
            }

            if let consumed = applyEmailOrDomain(in: &tokens, at: i) {
                changed = true
                i += consumed
                continue
            }

            if let result = applyCommand(in: &tokens, at: i, quoteOpen: &quoteOpen, capsLock: &capsLock) {
                changed = true
                if result.scratched { scratched = true }
                i = result.nextIndex
                continue
            }

            i += 1
        }

        let empty = Tokenizer.detokenize(tokens).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Outcome(tokens: tokens, changed: changed, wasScratched: scratched && empty)
    }

    private static func isPhraseStart(_ tokens: [Token], _ i: Int, _ words: [String]) -> Bool {
        match(tokens, i, words)
    }

    private static func applyCommand(
        in tokens: inout [Token],
        at i: Int,
        quoteOpen: inout Bool,
        capsLock: inout Bool
    ) -> CommandResult? {
        if match(tokens, i, ["never", "mind", "that"]) {
            return scratch(in: &tokens, at: i, length: 3)
        }
        if match(tokens, i, ["new", "paragraph"]) {
            return replaceWithNewline(&tokens, at: i, length: 2, count: 2)
        }
        if match(tokens, i, ["scratch", "that"]) || match(tokens, i, ["delete", "that"])
            || match(tokens, i, ["strike", "that"]) || match(tokens, i, ["undo", "that"]) {
            return scratch(in: &tokens, at: i, length: 2)
        }
        if match(tokens, i, ["new", "line"]) || match(tokens, i, ["newline"]) {
            let n = match(tokens, i, ["new", "line"]) ? 2 : 1
            return replaceWithNewline(&tokens, at: i, length: n, count: 1)
        }
        if match(tokens, i, ["exclamation", "point"]) || match(tokens, i, ["exclamation", "mark"]) {
            return replaceWithPunct(&tokens, at: i, length: 2, punct: "!")
        }
        if match(tokens, i, ["question", "mark"]) {
            return replaceWithPunct(&tokens, at: i, length: 2, punct: "?")
        }
        if match(tokens, i, ["open", "parenthesis"]) {
            return replaceWithOpen(&tokens, at: i, length: 2, punct: "(")
        }
        if match(tokens, i, ["close", "parenthesis"]) {
            return replaceWithClose(&tokens, at: i, length: 2, punct: ")")
        }
        if match(tokens, i, ["dot", "dot", "dot"]) {
            return replaceWithPunct(&tokens, at: i, length: 3, punct: "…")
        }
        if match(tokens, i, ["full", "stop"]) {
            return guardedPunct(&tokens, at: i, length: 2, punct: ".")
        }
        if match(tokens, i, ["open", "quote"]) {
            quoteOpen = true
            return replaceWithOpen(&tokens, at: i, length: 2, punct: "\"")
        }
        if match(tokens, i, ["close", "quote"]) || match(tokens, i, ["end", "quote"]) {
            quoteOpen = false
            return replaceWithClose(&tokens, at: i, length: 2, punct: "\"")
        }
        if match(tokens, i, ["open", "paren"]) {
            return replaceWithOpen(&tokens, at: i, length: 2, punct: "(")
        }
        if match(tokens, i, ["close", "paren"]) {
            return replaceWithClose(&tokens, at: i, length: 2, punct: ")")
        }
        if match(tokens, i, ["smiley", "face"]) {
            let t = Token(core: ":)", spaceBefore: tokens[i].spaceBefore, fromCommand: true)
            tokens.replaceSubrange(i..<(i + 2), with: [t])
            return CommandResult(nextIndex: i + 1, scratched: false)
        }
        if match(tokens, i, ["at", "sign"]) {
            return glueSymbol(&tokens, at: i, length: 2, symbol: "@", attachToNext: true)
        }
        if match(tokens, i, ["hash", "sign"]) || match(tokens, i, ["pound", "sign"]) {
            return glueSymbol(&tokens, at: i, length: 2, symbol: "#", attachToNext: true)
        }
        if match(tokens, i, ["percent", "sign"]) {
            return replaceWithPunct(&tokens, at: i, length: 2, punct: "%")
        }
        if match(tokens, i, ["dollar", "sign"]) {
            return glueSymbol(&tokens, at: i, length: 2, symbol: "$", attachToNext: true)
        }
        if match(tokens, i, ["forward", "slash"]) {
            return glueSymbol(&tokens, at: i, length: 2, symbol: "/", attachToNext: true)
        }
        if match(tokens, i, ["all", "caps"]) {
            return mutateNext(&tokens, at: i, length: 2) { $0.core = $0.core.uppercased() }
        }
        if match(tokens, i, ["caps", "lock", "on"]) {
            capsLock = true
            tokens.removeSubrange(i..<(i + 3))
            return CommandResult(nextIndex: i, scratched: false)
        }
        if match(tokens, i, ["caps", "lock", "off"]) {
            capsLock = false
            tokens.removeSubrange(i..<(i + 3))
            return CommandResult(nextIndex: i, scratched: false)
        }
        if match(tokens, i, ["no", "space"]) {
            return applyNoSpace(&tokens, at: i)
        }
        if match(tokens, i, ["new", "line"]) {
            return replaceWithNewline(&tokens, at: i, length: 2, count: 1)
        }
        if match(tokens, i, ["tab", "key"]) {
            return replaceWithTab(&tokens, at: i, length: 2)
        }
        if match(tokens, i, ["delete", "that"]) || match(tokens, i, ["undo", "that"]) {
            return scratch(in: &tokens, at: i, length: 2)
        }
        if match(tokens, i, ["open", "quote"]) { /* already handled */ }
        if match(tokens, i, ["hashtag"]) {
            return glueSymbol(&tokens, at: i, length: 1, symbol: "#", attachToNext: true)
        }
        if match(tokens, i, ["numeral"]) {
            return applyNumeral(&tokens, at: i)
        }
        if match(tokens, i, ["capitalize"]) || match(tokens, i, ["capital"]) {
            return mutateNext(&tokens, at: i, length: 1) { tok in
                tok.core = Tokenizer.capitalizeFirstLetter(tok.core)
            }
        }
        if match(tokens, i, ["unquote"]) || match(tokens, i, ["quote"]) {
            if match(tokens, i, ["unquote"]) || quoteOpen {
                quoteOpen = false
                return replaceWithClose(&tokens, at: i, length: 1, punct: "\"")
            } else {
                quoteOpen = true
                return replaceWithOpen(&tokens, at: i, length: 1, punct: "\"")
            }
        }
        if match(tokens, i, ["period"]) {
            return guardedPunct(&tokens, at: i, length: 1, punct: ".")
        }
        if match(tokens, i, ["comma"]) {
            return guardedPunct(&tokens, at: i, length: 1, punct: ",")
        }
        if match(tokens, i, ["colon"]) {
            return guardedPunct(&tokens, at: i, length: 1, punct: ":")
        }
        if match(tokens, i, ["semicolon"]) {
            return replaceWithPunct(&tokens, at: i, length: 1, punct: ";")
        }
        if match(tokens, i, ["hyphen"]) {
            return applyHyphen(&tokens, at: i)
        }
        if match(tokens, i, ["dash"]) {
            return guardedPunct(&tokens, at: i, length: 1, punct: "-")
        }
        if match(tokens, i, ["ellipsis"]) {
            return replaceWithPunct(&tokens, at: i, length: 1, punct: "…")
        }
        if match(tokens, i, ["ampersand"]) {
            return replaceWithSpaced(&tokens, at: i, length: 1, symbol: "&")
        }
        if match(tokens, i, ["slash"]) {
            return glueSymbol(&tokens, at: i, length: 1, symbol: "/", attachToNext: true)
        }
        if match(tokens, i, ["backslash"]) {
            return glueSymbol(&tokens, at: i, length: 1, symbol: "\\", attachToNext: true)
        }
        if match(tokens, i, ["underscore"]) {
            return glueSymbol(&tokens, at: i, length: 1, symbol: "_", attachToNext: true)
        }
        if match(tokens, i, ["asterisk"]) {
            return replaceWithPunct(&tokens, at: i, length: 1, punct: "*")
        }
        if match(tokens, i, ["dot"]), i + 1 < tokens.count, WordClass.tlds.contains(tokens[i + 1].lower) {
            return glueSymbol(&tokens, at: i, length: 2, symbol: "." + tokens[i + 1].core, attachToNext: false)
        }
        return nil
    }

    private static func applyEmailOrDomain(in tokens: inout [Token], at i: Int) -> Int? {
        func word(_ offset: Int) -> String? {
            let j = i + offset
            guard j < tokens.count, tokens[j].isWord else { return nil }
            return tokens[j].lower
        }
        // name at example dot com
        if word(1) == "at", word(3) == "dot", let tld = word(4), WordClass.tlds.contains(tld), word(0) != nil, word(2) != nil {
            var merged = tokens[i]
            merged.core = tokens[i].core + "@" + tokens[i + 2].core + "." + tokens[i + 4].core
            merged.trailing = tokens[i + 4].trailing
            merged.fromCommand = true
            tokens.replaceSubrange(i..<(i + 5), with: [merged])
            return 1
        }
        if word(1) == "at", word(2) == "sign", word(4) == "dot", let tld = word(5), WordClass.tlds.contains(tld), word(0) != nil, word(3) != nil {
            var merged = tokens[i]
            merged.core = tokens[i].core + "@" + tokens[i + 3].core + "." + tokens[i + 5].core
            merged.trailing = tokens[i + 5].trailing
            merged.fromCommand = true
            tokens.replaceSubrange(i..<(i + 6), with: [merged])
            return 1
        }
        if word(1) == "dot", let tld = word(2), WordClass.tlds.contains(tld), word(0) != nil {
            var merged = tokens[i]
            merged.core = tokens[i].core + "." + tokens[i + 2].core
            merged.trailing = tokens[i + 2].trailing
            merged.fromCommand = true
            tokens.replaceSubrange(i..<(i + 3), with: [merged])
            return 1
        }
        return nil
    }

    private static func match(_ tokens: [Token], _ i: Int, _ words: [String]) -> Bool {
        guard i + words.count <= tokens.count else { return false }
        for (offset, word) in words.enumerated() {
            let t = tokens[i + offset]
            if t.isNewline || t.frozen || !t.isWord { return false }
            if t.lower != word { return false }
        }
        return true
    }

    private static func isLastWord(tokens: [Token], lastIndex: Int) -> Bool {
        var j = lastIndex + 1
        while j < tokens.count {
            if tokens[j].isWord { return false }
            j += 1
        }
        return true
    }

    private static func nextWordCapitalized(tokens: [Token], after lastIndex: Int) -> Bool {
        var j = lastIndex + 1
        while j < tokens.count {
            if tokens[j].isNewline { return false }
            if tokens[j].isWord {
                if let c = tokens[j].core.first { return c.isUppercase }
                return false
            }
            j += 1
        }
        return false
    }

    private static func previousEndsClause(_ tokens: [Token], before i: Int) -> Bool {
        var j = i - 1
        while j >= 0 {
            if tokens[j].isNewline || tokens[j].endsClause { return true }
            if tokens[j].fromCommand {
                if tokens[j].visible.contains(where: { ".?!,;:".contains($0) }) { return true }
            }
            if tokens[j].isWord { return false }
            j -= 1
        }
        return false
    }

    private static func precededByCommand(_ tokens: [Token], before i: Int) -> Bool {
        var j = i - 1
        while j >= 0 {
            if tokens[j].fromCommand { return true }
            if tokens[j].isWord || tokens[j].isNewline { return false }
            j -= 1
        }
        return false
    }

    private static func guardedPunct(_ tokens: inout [Token], at i: Int, length: Int, punct: String) -> CommandResult? {
        let last = i + length - 1
        // Natural usage: "the trial period", "a dash of salt", "use a comma here".
        if let next = nextWordToken(tokens, after: last), let first = next.core.first, first.isLowercase {
            return nil
        }
        if isLastWord(tokens: tokens, lastIndex: last) {
            return replaceWithPunct(&tokens, at: i, length: length, punct: punct)
        }
        if precededByCommand(tokens, before: i) {
            return replaceWithPunct(&tokens, at: i, length: length, punct: punct)
        }
        if previousEndsClause(tokens, before: i) && nextWordCapitalized(tokens: tokens, after: last) {
            return replaceWithPunct(&tokens, at: i, length: length, punct: punct)
        }
        return nil
    }

    private static func nextWordToken(_ tokens: [Token], after lastIndex: Int) -> Token? {
        var j = lastIndex + 1
        while j < tokens.count {
            if tokens[j].isNewline { return nil }
            if tokens[j].isWord { return tokens[j] }
            j += 1
        }
        return nil
    }

    private static func replaceWithPunct(_ tokens: inout [Token], at i: Int, length: Int, punct: String) -> CommandResult {
        if i > 0 {
            var prev = i - 1
            while prev >= 0 && tokens[prev].isNewline { prev -= 1 }
            if prev >= 0 {
                tokens[prev].trailing += punct
                tokens[prev].fromCommand = true
                tokens.removeSubrange(i..<(i + length))
                if i < tokens.count {
                    tokens[i].spaceBefore = true
                }
                return CommandResult(nextIndex: i, scratched: false)
            }
        }
        let t = Token(core: punct, spaceBefore: false, fromCommand: true)
        tokens.replaceSubrange(i..<(i + length), with: [t])
        return CommandResult(nextIndex: i + 1, scratched: false)
    }

    private static func replaceWithOpen(_ tokens: inout [Token], at i: Int, length: Int, punct: String) -> CommandResult {
        let t = Token(core: punct, spaceBefore: tokens[i].spaceBefore, fromCommand: true)
        tokens.replaceSubrange(i..<(i + length), with: [t])
        if i + 1 < tokens.count {
            tokens[i + 1].spaceBefore = false
        }
        return CommandResult(nextIndex: i + 1, scratched: false)
    }

    private static func replaceWithClose(_ tokens: inout [Token], at i: Int, length: Int, punct: String) -> CommandResult {
        if i > 0 {
            tokens[i - 1].trailing += punct
            tokens[i - 1].fromCommand = true
            tokens.removeSubrange(i..<(i + length))
            if i < tokens.count {
                tokens[i].spaceBefore = true
            }
            return CommandResult(nextIndex: i, scratched: false)
        }
        let t = Token(core: punct, spaceBefore: false, fromCommand: true)
        tokens.replaceSubrange(i..<(i + length), with: [t])
        return CommandResult(nextIndex: i + 1, scratched: false)
    }

    private static func replaceWithNewline(_ tokens: inout [Token], at i: Int, length: Int, count: Int) -> CommandResult {
        let t = Token(core: String(repeating: "\n", count: count), isNewline: true, fromCommand: true)
        tokens.replaceSubrange(i..<(i + length), with: [t])
        if i + 1 < tokens.count {
            tokens[i + 1].spaceBefore = false
        }
        return CommandResult(nextIndex: i + 1, scratched: false)
    }

    private static func replaceWithTab(_ tokens: inout [Token], at i: Int, length: Int) -> CommandResult {
        let t = Token(core: "\t", spaceBefore: false, fromCommand: true)
        tokens.replaceSubrange(i..<(i + length), with: [t])
        if i + 1 < tokens.count {
            tokens[i + 1].spaceBefore = false
        }
        return CommandResult(nextIndex: i + 1, scratched: false)
    }

    private static func glueSymbol(_ tokens: inout [Token], at i: Int, length: Int, symbol: String, attachToNext: Bool) -> CommandResult {
        let after = i + length
        if attachToNext, after < tokens.count, tokens[after].isWord {
            tokens[after].core = symbol + tokens[after].core
            tokens[after].fromCommand = true
            tokens[after].spaceBefore = tokens[i].spaceBefore
            tokens.removeSubrange(i..<after)
            return CommandResult(nextIndex: i + 1, scratched: false)
        }
        if i > 0, tokens[i - 1].isWord {
            tokens[i - 1].core += symbol
            tokens[i - 1].fromCommand = true
            tokens.removeSubrange(i..<(i + length))
            return CommandResult(nextIndex: i, scratched: false)
        }
        let t = Token(core: symbol, spaceBefore: tokens[i].spaceBefore, fromCommand: true)
        tokens.replaceSubrange(i..<(i + length), with: [t])
        return CommandResult(nextIndex: i + 1, scratched: false)
    }

    private static func mutateNext(_ tokens: inout [Token], at i: Int, length: Int, mutate: (inout Token) -> Void) -> CommandResult? {
        let next = i + length
        guard next < tokens.count, tokens[next].isWord else { return nil }
        mutate(&tokens[next])
        tokens[next].fromCommand = true
        tokens.removeSubrange(i..<(i + length))
        return CommandResult(nextIndex: i, scratched: false)
    }

    private static func applyNoSpace(_ tokens: inout [Token], at i: Int) -> CommandResult? {
        guard i + 1 < tokens.count else {
            tokens.remove(at: i)
            return CommandResult(nextIndex: i, scratched: false)
        }
        // Join the word before with the word after.
        var next = i + 1
        if match(tokens, i, ["no", "space"]) { next = i + 2 }
        guard next < tokens.count, tokens[next].isWord else { return nil }
        if i > 0, tokens[i - 1].isWord {
            tokens[i - 1].core += tokens[next].core
            tokens[i - 1].trailing = tokens[next].trailing
            tokens[i - 1].fromCommand = true
            tokens.removeSubrange(i...(next))
            return CommandResult(nextIndex: i, scratched: false)
        }
        tokens[next].spaceBefore = false
        tokens.removeSubrange(i..<next)
        return CommandResult(nextIndex: i, scratched: false)
    }

    private static func applyNumeral(_ tokens: inout [Token], at i: Int) -> CommandResult? {
        let next = i + 1
        guard next < tokens.count, tokens[next].isWord else { return nil }
        if let value = NumberWords.parsePhrase(from: tokens, at: next) {
            var t = tokens[next]
            t.core = NumberWords.format(value.value, forceDigits: true, decimal: value.decimal)
            t.trailing = tokens[value.end - 1].trailing
            t.fromCommand = true
            t.spaceBefore = tokens[i].spaceBefore
            tokens.replaceSubrange(i..<value.end, with: [t])
            return CommandResult(nextIndex: i + 1, scratched: false)
        }
        tokens.remove(at: i)
        return CommandResult(nextIndex: i, scratched: false)
    }

    private static func applyHyphen(_ tokens: inout [Token], at i: Int) -> CommandResult {
        let after = i + 1
        if i > 0, tokens[i - 1].isWord, after < tokens.count, tokens[after].isWord {
            tokens[i - 1].core += "-" + tokens[after].core
            tokens[i - 1].trailing = tokens[after].trailing
            tokens[i - 1].fromCommand = true
            tokens.removeSubrange(i...(after))
            return CommandResult(nextIndex: i, scratched: false)
        }
        return replaceWithPunct(&tokens, at: i, length: 1, punct: "-")
    }

    private static func replaceWithSpaced(_ tokens: inout [Token], at i: Int, length: Int, symbol: String) -> CommandResult {
        let t = Token(core: symbol, spaceBefore: true, fromCommand: true)
        tokens.replaceSubrange(i..<(i + length), with: [t])
        if i + 1 < tokens.count {
            tokens[i + 1].spaceBefore = true
        }
        return CommandResult(nextIndex: i + 1, scratched: false)
    }

    private static func scratch(in tokens: inout [Token], at i: Int, length: Int) -> CommandResult {
        var start = Tokenizer.lastClauseStart(tokens: tokens, before: i)
        let wordsBefore = tokens[start..<i].contains(where: { $0.isWord })
        if !wordsBefore, start > 0 {
            start = Tokenizer.lastClauseStart(tokens: tokens, before: start - 1)
        }
        var end = i + length
        if end < tokens.count, tokens[end].isSeparator { end += 1 }
        tokens.removeSubrange(start..<end)
        if start < tokens.count {
            tokens[start].spaceBefore = start > 0 && !tokens[start - 1].isNewline
            if Tokenizer.isSentenceStart(tokens: tokens, index: start), tokens[start].isWord {
                tokens[start].core = Tokenizer.capitalizeFirstLetter(tokens[start].core)
            }
        }
        let empty = tokens.allSatisfy { $0.isNewline || $0.visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return CommandResult(nextIndex: start, scratched: empty)
    }
}
