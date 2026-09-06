import Foundation

/// Spelled-out English number parsing used by smart formatting and the `numeral` command.
enum NumberWords {
    struct Parsed {
        var value: Double
        var end: Int
        var decimal: Bool
        var ordinal: Bool
        var wordCount: Int
    }

    static let ones: [String: Int] = [
        "zero": 0, "oh": 0, "nought": 0,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]

    static let scales: [String: Int] = [
        "hundred": 100,
        "thousand": 1_000,
        "million": 1_000_000,
        "billion": 1_000_000_000,
    ]

    static func isNumberWord(_ w: String) -> Bool {
        let l = w.lowercased()
        return ones[l] != nil || teens[l] != nil || tens[l] != nil || scales[l] != nil
            || ordinals[l] != nil || l == "and" || l == "point"
    }

    static func parsePhrase(from tokens: [Token], at start: Int) -> Parsed? {
        guard start < tokens.count, tokens[start].isWord else { return nil }
        var i = start
        var total = 0
        var current = 0
        var consumed = false
        var decimalPart: String?
        var ordinal = false
        var wordCount = 0

        func commitCurrent() {
            total += current
            current = 0
        }

        while i < tokens.count, tokens[i].isWord {
            let w = tokens[i].lower
            if w == "and", consumed, i + 1 < tokens.count, tokens[i + 1].isWord, isMagnitude(tokens[i + 1].lower) {
                i += 1
                continue
            }
            if w == "point", consumed, i + 1 < tokens.count, tokens[i + 1].isWord {
                i += 1
                var digits = ""
                while i < tokens.count, tokens[i].isWord {
                    let lw = tokens[i].lower
                    if let d = ones[lw], d <= 9 {
                        digits.append(String(d))
                        i += 1
                        wordCount += 1
                    } else {
                        break
                    }
                }
                if !digits.isEmpty {
                    decimalPart = digits
                    consumed = true
                }
                break
            }
            if let v = ones[w] {
                // Don't glue adjacent small digits ("four five six"); "twenty three" is tens+ones.
                if consumed, current > 0, current < 10, tens[w] == nil {
                    break
                }
                if consumed, current >= 10, current < 20 {
                    break
                }
                current += v
                consumed = true
                wordCount += 1
                i += 1
                continue
            }
            if let v = teens[w] {
                current += v
                consumed = true
                wordCount += 1
                i += 1
                continue
            }
            if let v = tens[w] {
                current += v
                consumed = true
                wordCount += 1
                i += 1
                continue
            }
            if let v = ordinals[w] {
                current += v
                ordinal = true
                consumed = true
                wordCount += 1
                i += 1
                break
            }
            if let scale = scales[w] {
                if scale == 100 {
                    if current == 0 { current = 1 }
                    current *= 100
                    consumed = true
                    wordCount += 1
                    i += 1
                    continue
                } else {
                    if current == 0 { current = 1 }
                    current *= scale
                    commitCurrent()
                    consumed = true
                    wordCount += 1
                    i += 1
                    continue
                }
            }
            break
        }

        guard consumed else { return nil }
        commitCurrent()
        var value = Double(total)
        var decimal = false
        if let frac = decimalPart, let f = Double("0." + frac) {
            value += f
            decimal = true
        }
        return Parsed(value: value, end: i, decimal: decimal, ordinal: ordinal, wordCount: wordCount)
    }

    private static func isMagnitude(_ w: String) -> Bool {
        ones[w] != nil || teens[w] != nil || tens[w] != nil || ordinals[w] != nil || scales[w] != nil
    }

    static func format(_ value: Double, forceDigits: Bool, decimal: Bool) -> String {
        if decimal {
            var s = String(value)
            if s.hasSuffix(".0") { s = String(s.dropLast(2)) }
            return s
        }
        let intVal = Int(value.rounded(.towardZero))
        if !forceDigits, abs(value - Double(intVal)) < 0.0001, intVal >= 1, intVal <= 9 {
            return ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"][intVal]
        }
        return formatInt(intVal)
    }

    static func formatInt(_ value: Int) -> String {
        let absVal = abs(value)
        if absVal >= 10_000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            formatter.usesGroupingSeparator = true
            formatter.maximumFractionDigits = 0
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        return String(value)
    }

    static func ordinalSuffix(_ value: Int) -> String {
        let n = abs(value)
        let mod100 = n % 100
        let mod10 = n % 10
        let suffix: String
        if mod100 >= 11 && mod100 <= 13 {
            suffix = "th"
        } else {
            switch mod10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return String(n) + suffix
    }
}

/// Converts spelled-out numbers, currency, times, emails and URLs.
enum NumberFormatting {
    private static let unitsFollowingSmall: Set<String> = [
        "percent", "percentage", "dollars", "dollar", "euros", "euro", "pounds", "pound",
        "pm", "am", "o'clock", "oclock", "million", "billion", "thousand", "k",
        "percent",
    ]

    private static let tlds = WordClass.tlds

    struct Outcome {
        var tokens: [Token]
        var changed: Bool
        var stages: [String]
    }

    static func apply(_ tokens: [Token]) -> Outcome {
        var tokens = tokens
        var stages: [String] = []
        let before = Tokenizer.detokenize(tokens)

        applyEmailsAndURLs(&tokens)
        applyTimesAndNumbers(&tokens)
        applyCurrencyAndPercent(&tokens)

        let after = Tokenizer.detokenize(tokens)
        if after != before {
            stages.append("numbers")
        }
        return Outcome(tokens: tokens, changed: after != before, stages: stages)
    }

    private static func applyEmailsAndURLs(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            if let consumed = glueWWW(&tokens, at: i) {
                i += consumed
                continue
            }
            if let consumed = glueEmail(&tokens, at: i) {
                i += consumed
                continue
            }
            if let consumed = glueURL(&tokens, at: i) {
                i += consumed
                continue
            }
            i += 1
        }
    }

    private static func glueWWW(_ tokens: inout [Token], at i: Int) -> Int? {
        guard i + 3 < tokens.count else { return nil }
        guard tokens[i].lower == "w", tokens[i + 1].lower == "w", tokens[i + 2].lower == "w",
              tokens[i + 3].lower == "dot" else { return nil }
        var host: [String] = []
        var k = i + 4
        var sawDot = false
        while k < tokens.count, tokens[k].isWord {
            let w = tokens[k].lower
            if w == "dot" {
                sawDot = true
                k += 1
                continue
            }
            if w == "slash" || w == "forward" { break }
            host.append(tokens[k].core)
            k += 1
            if host.count > 6 { break }
            if let last = host.last, tlds.contains(last.lowercased()), sawDot { break }
        }
        var merged = tokens[i]
        if host.isEmpty {
            merged.core = "www."
        } else {
            merged.core = "www." + host.joined(separator: ".")
        }
        merged.fromCommand = true
        if k > i { merged.trailing = tokens[k - 1].trailing }
        tokens.replaceSubrange(i..<k, with: [merged])
        return 1
    }

    private static func glueEmail(_ tokens: inout [Token], at i: Int) -> Int? {
        // Find "at" not at index 0, then later "dot" + tld.
        guard tokens[i].isWord, tokens[i].lower != "at" else { return nil }
        var sawAt = false
        var atIndex = -1
        var k = i
        // Local part: words and "dot"
        var localPieces: [String] = []
        while k < tokens.count, tokens[k].isWord {
            let w = tokens[k].lower
            if w == "at" {
                sawAt = true
                atIndex = k
                break
            }
            if w == "dot" {
                k += 1
                continue
            }
            localPieces.append(tokens[k].core)
            k += 1
            if k - i > 8 { break }
        }
        guard sawAt, !localPieces.isEmpty else { return nil }
        var hostPieces: [String] = []
        var p = atIndex + 1
        while p < tokens.count, tokens[p].isWord {
            let w = tokens[p].lower
            if w == "dot" {
                p += 1
                continue
            }
            if w == "slash" || w == "forward" { break }
            hostPieces.append(tokens[p].core)
            p += 1
            if hostPieces.count > 6 { break }
        }
        guard hostPieces.count >= 2 else { return nil }
        let tld = hostPieces.last!.lowercased()
        guard tlds.contains(tld) else { return nil }
        // Require at least one spoken "dot" before the TLD.
        var sawDot = false
        var q = atIndex + 1
        while q < p {
            if tokens[q].lower == "dot" { sawDot = true; break }
            q += 1
        }
        guard sawDot else { return nil }

        var merged = tokens[i]
        let local = localPieces.joined(separator: ".")
        let host = hostPieces.joined(separator: ".")
        merged.core = local + "@" + host
        merged.trailing = tokens[p - 1].trailing
        merged.fromCommand = true
        tokens.replaceSubrange(i..<p, with: [merged])
        return 1
    }

    private static func glueURL(_ tokens: inout [Token], at i: Int) -> Int? {
        guard tokens[i].isWord else { return nil }
        // example dot com (slash docs)?
        var pieces: [String] = []
        var k = i
        var sawDot = false
        while k < tokens.count, tokens[k].isWord {
            let w = tokens[k].lower
            if w == "dot" {
                sawDot = true
                k += 1
                continue
            }
            if w == "slash" || (w == "forward" && k + 1 < tokens.count && tokens[k + 1].lower == "slash") {
                break
            }
            pieces.append(tokens[k].core)
            k += 1
            if pieces.count > 6 { break }
        }
        guard sawDot, pieces.count >= 2, tlds.contains(pieces.last!.lowercased()) else { return nil }
        // Don't steal emails (those have "at").
        for t in tokens[i..<k] {
            if t.lower == "at" { return nil }
        }
        let cleaned = pieces.map { p in
            p.hasSuffix(".") ? String(p.dropLast()) : p
        }
        var core = cleaned.joined(separator: ".")
        var end = k
        if k < tokens.count {
            var slashAt = k
            if tokens[k].lower == "forward", k + 1 < tokens.count, tokens[k + 1].lower == "slash" {
                slashAt = k + 1
            }
            if tokens[slashAt].lower == "slash" || tokens[slashAt].lower == "backslash" {
                core += "/"
                var p = slashAt + 1
                var path: [String] = []
                while p < tokens.count, tokens[p].isWord {
                    let w = tokens[p].lower
                    if w == "slash" || w == "dot" {
                        if w == "slash" { path.append("/") }
                        else { path.append(".") }
                        p += 1
                        continue
                    }
                    path.append(tokens[p].core)
                    p += 1
                    if path.count > 8 { break }
                }
                if !path.isEmpty {
                    core += path.joined()
                    end = p
                } else {
                    end = slashAt + 1
                }
            }
        }
        var merged = tokens[i]
        merged.core = core
        merged.trailing = tokens[end - 1].trailing
        merged.fromCommand = true
        tokens.replaceSubrange(i..<end, with: [merged])
        return 1
    }

    private static func applyTimesAndNumbers(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            if let consumed = applyTime(in: &tokens, at: i) {
                i += consumed
                continue
            }
            if let consumed = applyNumber(in: &tokens, at: i) {
                i += consumed
                continue
            }
            i += 1
        }
    }

    private static func peekLower(_ tokens: [Token], _ i: Int) -> String? {
        guard i < tokens.count, tokens[i].isWord else { return nil }
        return tokens[i].lower
    }

    private static func isAMPM(_ w: String) -> Bool {
        w == "am" || w == "pm" || w == "a.m." || w == "p.m." || w == "a.m" || w == "p.m"
    }

    private static func normalizeAMPM(_ tokens: [Token], at i: Int) -> (label: String, end: Int)? {
        guard i < tokens.count else { return nil }
        let w = tokens[i].lower
        if w == "pm" || w == "p.m." || w == "p.m" { return ("PM", i + 1) }
        if w == "am" || w == "a.m." || w == "a.m" { return ("AM", i + 1) }
        // "p m" / "a m"
        if (w == "p" || w == "a"), i + 1 < tokens.count, tokens[i + 1].lower == "m" {
            return (w == "p" ? "PM" : "AM", i + 2)
        }
        return nil
    }

    private static func hourValue(_ token: Token) -> Int? {
        if let n = Int(token.core), n >= 0, n <= 23 { return n }
        if let parsed = NumberWords.parsePhrase(from: [token], at: 0) {
            let v = Int(parsed.value)
            if v >= 0 && v <= 23 { return v }
        }
        return nil
    }

    private static func minuteValue(from tokens: [Token], at i: Int) -> (Int, Int)? {
        guard i < tokens.count else { return nil }
        if let n = Int(tokens[i].core), n >= 0, n <= 59 {
            return (n, i + 1)
        }
        guard let parsed = NumberWords.parsePhrase(from: tokens, at: i) else { return nil }
        let v = Int(parsed.value)
        if v >= 0 && v <= 59 { return (v, parsed.end) }
        return nil
    }

    private static func applyTime(in tokens: inout [Token], at i: Int) -> Int? {
        guard tokens[i].isWord else { return nil }
        // half past — leave
        if tokens[i].lower == "half" { return nil }

        guard let hour = hourValue(tokens[i]) else { return nil }

        var j = i + 1
        var minutes: Int?
        var label: String?

        if let (m, end) = minuteValue(from: tokens, at: j), m > 0, m <= 59,
           NumberWords.parsePhrase(from: tokens, at: j) != nil || Int(tokens[j].core) != nil {
            // Only treat as minutes when followed by am/pm or the minute word is tens (thirty, forty-five…)
            let looksLikeMinutes = tokens[j].lower == "thirty" || tokens[j].lower == "fifteen"
                || tokens[j].lower == "forty" || tokens[j].lower == "forty-five"
                || tokens[j].lower == "ten" || tokens[j].lower == "twenty"
                || tokens[j].lower == "fifty" || tokens[j].lower == "o"
                || (end < tokens.count && normalizeAMPM(tokens, at: end) != nil)
            if looksLikeMinutes {
                minutes = m
                j = end
            }
        }

        if let amp = normalizeAMPM(tokens, at: j) {
            label = amp.label
            j = amp.end
        } else if j < tokens.count, peekLower(tokens, j) == "o'clock" || peekLower(tokens, j) == "oclock" {
            j += 1
            // leave as converted hour without AM/PM
        } else if minutes == nil {
            return nil
        }

        // Already-digit hours with only an AM/PM label stay as spoken (e.g. "4 pm").
        if minutes == nil, Int(tokens[i].core) != nil, label != nil {
            return nil
        }

        var core: String
        if let minutes, minutes > 0 {
            core = "\(hour):\(String(format: "%02d", minutes))"
        } else {
            core = "\(hour)"
        }
        if let label {
            core += " \(label)"
        }
        var merged = tokens[i]
        merged.core = core
        merged.trailing = tokens[j - 1].trailing
        merged.fromCommand = true
        tokens.replaceSubrange(i..<j, with: [merged])
        return 1
    }

    private static func previousWord(_ tokens: [Token], before i: Int) -> Token? {
        var j = i - 1
        while j >= 0 {
            if tokens[j].isWord { return tokens[j] }
            j -= 1
        }
        return nil
    }

    private static func nextWord(_ tokens: [Token], after i: Int) -> Token? {
        var j = i
        while j < tokens.count {
            if tokens[j].isWord { return tokens[j] }
            j += 1
        }
        return nil
    }

    private static func applyNumber(in tokens: inout [Token], at i: Int) -> Int? {
        guard tokens[i].isWord else { return nil }
        // Already digits.
        if WordClass.isNumeral(tokens[i].core), onesOrTeens(tokens[i].lower) == nil, NumberWords.tens[tokens[i].lower] == nil,
           NumberWords.ones[tokens[i].lower] == nil, NumberWords.teens[tokens[i].lower] == nil,
           NumberWords.ordinals[tokens[i].lower] == nil, NumberWords.scales[tokens[i].lower] == nil {
            return nil
        }
        guard let parsed = NumberWords.parsePhrase(from: tokens, at: i) else { return nil }

        let following = parsed.end < tokens.count ? tokens[parsed.end] : nil
        let followingLower = following?.isWord == true ? following!.lower : nil
        let prev = previousWord(tokens, before: i)

        // Digit list: "four five six" — leave.
        if parsed.wordCount == 1, let v = NumberWords.ones[tokens[i].lower], v >= 1, v <= 9,
           let next = followingLower, NumberWords.ones[next] != nil {
            return nil
        }

        // Pronoun "one": not followed by number word or unit.
        if tokens[i].lower == "one", parsed.wordCount == 1 {
            let unit = followingLower.map { unitsFollowingSmall.contains($0) || NumberWords.scales[$0] != nil } ?? false
            let nextNumber = followingLower.map { NumberWords.isNumberWord($0) && $0 != "and" } ?? false
            let precededForce = prev.map { $0.core == "#" || $0.lower == "number" || $0.lower == "version" } ?? false
            if !unit && !nextNumber && !precededForce {
                return nil
            }
        }

        let value = parsed.value
        let intVal = Int(value.rounded(.towardZero))
        let forceByUnit = followingLower.map { unitsFollowingSmall.contains($0) } ?? false
        let forceByPrev = prev.map { $0.core == "#" || $0.lower == "number" || $0.lower == "version" } ?? false
        let force = forceByUnit || forceByPrev || parsed.decimal

        if parsed.ordinal {
            if parsed.wordCount == 1, NumberWords.ordinals[tokens[i].lower] != nil, intVal < 10 {
                // "third" alone stays
                return nil
            }
            var t = tokens[i]
            t.core = NumberWords.ordinalSuffix(intVal)
            t.trailing = tokens[parsed.end - 1].trailing
            t.fromCommand = true
            tokens.replaceSubrange(i..<parsed.end, with: [t])
            return 1
        }

        if !force, !parsed.decimal, value < 10, value >= 1, parsed.wordCount == 1 {
            return nil
        }

        if value < 10, !force, parsed.wordCount == 1 {
            return nil
        }

        var t = tokens[i]
        if parsed.decimal {
            var s = String(value)
            if let dot = s.firstIndex(of: ".") {
                let frac = s[s.index(after: dot)...]
                if frac.count > 4 { s = String(format: "%g", value) }
            }
            t.core = s
        } else {
            t.core = NumberWords.formatInt(intVal)
        }
        t.trailing = tokens[parsed.end - 1].trailing
        t.fromCommand = true
        tokens.replaceSubrange(i..<parsed.end, with: [t])
        return 1
    }

    private static func onesOrTeens(_ w: String) -> Int? {
        NumberWords.ones[w] ?? NumberWords.teens[w]
    }

    private static func applyCurrencyAndPercent(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            if tokens[i].isWord, isNumericCore(tokens[i].core), i + 1 < tokens.count {
                let next = tokens[i + 1].lower
                if next == "percent" || next == "percentage" {
                    tokens[i].core = tokens[i].core + "%"
                    tokens[i].trailing = tokens[i + 1].trailing
                    tokens.remove(at: i + 1)
                    i += 1
                    continue
                }
                if next == "dollars" || next == "dollar" {
                    applyMoney(&tokens, at: i, symbol: "$")
                    i += 1
                    continue
                }
                if next == "euros" || next == "euro" {
                    applyMoney(&tokens, at: i, symbol: "€")
                    i += 1
                    continue
                }
                if next == "pounds" || next == "pound" {
                    applyMoney(&tokens, at: i, symbol: "£")
                    i += 1
                    continue
                }
            }
            i += 1
        }
    }

    private static func isNumericCore(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: ",", with: "")
        return Double(stripped) != nil
    }

    private static func applyMoney(_ tokens: inout [Token], at i: Int, symbol: String) {
        var amount = tokens[i].core
        var end = i + 2 // number + dollars
        // "X dollars and Y cents"
        if symbol == "$",
           end + 2 < tokens.count,
           tokens[end].lower == "and",
           isNumericCore(tokens[end + 1].core) || NumberWords.parsePhrase(from: tokens, at: end + 1) != nil,
           end + 2 < tokens.count,
           tokens[end + 2].lower == "cents" || tokens[end + 2].lower == "cent" {
            let centsToken = tokens[end + 1]
            var cents: Int = 0
            if let n = Int(centsToken.core) {
                cents = n
            } else if let parsed = NumberWords.parsePhrase(from: tokens, at: end + 1) {
                cents = Int(parsed.value)
            }
            let centsStr = String(format: "%02d", cents)
            amount = amount + "." + centsStr
            end = end + 3
        }
        tokens[i].core = symbol + amount
        tokens[i].trailing = tokens[end - 1].trailing
        tokens.removeSubrange((i + 1)..<end)
    }
}
