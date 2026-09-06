import Foundation
import AlethiaCore

/// Flags that control which dictation cleanup stages run.
public struct FormattingOptions: Sendable, Hashable {
    public var removeFillers: Bool
    public var resolveSelfCorrections: Bool
    public var applyVoiceCommands: Bool
    public var smartFormatting: Bool
    public var appAwareStyle: Bool
    /// Compatibility: dictionary entries may also live on `FormattingContext`.
    public var dictionary: [DictionaryEntry]
    /// Compatibility: snippets may also live on `FormattingContext`.
    public var snippets: [Snippet]

    public init(
        removeFillers: Bool = true,
        resolveSelfCorrections: Bool = true,
        applyVoiceCommands: Bool = true,
        smartFormatting: Bool = true,
        appAwareStyle: Bool = true,
        dictionary: [DictionaryEntry] = [],
        snippets: [Snippet] = []
    ) {
        self.removeFillers = removeFillers
        self.resolveSelfCorrections = resolveSelfCorrections
        self.applyVoiceCommands = applyVoiceCommands
        self.smartFormatting = smartFormatting
        self.appAwareStyle = appAwareStyle
        self.dictionary = dictionary
        self.snippets = snippets
    }

    /// Copies the matching flags from persisted dictation settings.
    public init(settings: DictationSettings) {
        self.removeFillers = settings.removeFillers
        self.resolveSelfCorrections = settings.resolveSelfCorrections
        self.applyVoiceCommands = settings.applyVoiceCommands
        self.smartFormatting = settings.smartFormatting
        self.appAwareStyle = settings.appAwareStyle
        self.dictionary = []
        self.snippets = []
    }
}

/// Inputs that accompany a raw recognizer string through the formatter.
public struct FormattingContext: Sendable, Hashable {
    public var style: AppStyle
    public var options: FormattingOptions
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    public var language: String
    /// Optional text before the insertion point, used to join mid-sentence dictation.
    public var precedingText: String?

    public init(
        style: AppStyle = .standard,
        options: FormattingOptions = FormattingOptions(),
        dictionary: [DictionaryEntry] = [],
        snippets: [Snippet] = [],
        language: String = "en",
        precedingText: String? = nil
    ) {
        self.style = style
        self.options = options
        self.dictionary = dictionary
        self.snippets = snippets
        self.language = language
        self.precedingText = precedingText
    }
}

/// Result of running `DictationFormatter` on a raw utterance.
public struct FormattingResult: Sendable, Hashable {
    public var text: String
    /// Names of stages that changed something.
    public var appliedStages: [String]
    public var firedDictionaryEntryIDs: [UUID]
    public var expandedSnippetIDs: [UUID]
    /// True if a "scratch that" (or synonym) removed everything.
    public var wasScratched: Bool

    public init(
        text: String,
        appliedStages: [String] = [],
        firedDictionaryEntryIDs: [UUID] = [],
        expandedSnippetIDs: [UUID] = [],
        wasScratched: Bool = false
    ) {
        self.text = text
        self.appliedStages = appliedStages
        self.firedDictionaryEntryIDs = firedDictionaryEntryIDs
        self.expandedSnippetIDs = expandedSnippetIDs
        self.wasScratched = wasScratched
    }

    /// True when the utterance was only control words and nothing should be inserted.
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var usedDictionaryIDs: [UUID] { firedDictionaryEntryIDs }
    public var usedSnippetIDs: [UUID] { expandedSnippetIDs }
}

/// Compatibility alias for `FormattingResult`.
public typealias FormattedText = FormattingResult

/// Deterministic, rule-based cleanup of speech-recognizer dictation output.
public struct DictationFormatter: Sendable {
    public init() {}

    /// Formats `raw` recognizer text using `context`.
    public func format(_ raw: String, context: FormattingContext) -> FormattingResult {
        let options = context.options
        var stages: [String] = []
        var dictIDs: [UUID] = []
        var snippetIDs: [UUID] = []
        let english = context.language.lowercased().hasPrefix("en") || context.language.isEmpty
        let dictionary = context.dictionary.isEmpty ? options.dictionary : context.dictionary
        let snippets = context.snippets.isEmpty ? options.snippets : context.snippets

        var text = Tokenizer.normalize(raw)
        if text.isEmpty {
            return FormattingResult(text: "")
        }

        var tokens = Tokenizer.tokenize(text)

        // Spec order: normalize → voice commands → self-correction → fillers → dictionary → snippets → smart.
        if options.applyVoiceCommands, english {
            let outcome = VoiceCommands.apply(tokens)
            tokens = outcome.tokens
            text = Tokenizer.detokenize(tokens)
            if outcome.wasScratched {
                if outcome.changed { stages.append("voice-commands") }
                return FormattingResult(
                    text: "",
                    appliedStages: stages,
                    firedDictionaryEntryIDs: dictIDs,
                    expandedSnippetIDs: snippetIDs,
                    wasScratched: true
                )
            }
            if outcome.changed { stages.append("voice-commands") }
        }

        if options.resolveSelfCorrections, english {
            let outcome = SelfCorrection.apply(tokens)
            tokens = outcome.tokens
            text = Tokenizer.detokenize(tokens)
            if outcome.wasScratched {
                if outcome.changed { stages.append("self-correction") }
                return FormattingResult(
                    text: "",
                    appliedStages: stages,
                    firedDictionaryEntryIDs: dictIDs,
                    expandedSnippetIDs: snippetIDs,
                    wasScratched: true
                )
            }
            if outcome.changed { stages.append("self-correction") }
        }

        if options.removeFillers, english {
            let before = Tokenizer.detokenize(tokens)
            tokens = Fillers.apply(tokens)
            text = Fillers.cleanupString(Tokenizer.detokenize(tokens))
            tokens = Tokenizer.tokenize(text)
            if text != before { stages.append("fillers") }
        }

        if !dictionary.isEmpty {
            let before = Tokenizer.detokenize(tokens)
            let dict = applyDictionary(tokens: tokens, entries: dictionary)
            tokens = dict.tokens
            text = Tokenizer.detokenize(tokens)
            dictIDs = dict.fired
            if !dictIDs.isEmpty || text != before {
                stages.append("dictionary")
            }
        }

        if !snippets.isEmpty {
            let snippet = applySnippets(text: text, tokens: tokens, snippets: snippets)
            if snippet.replacedEntire {
                return FormattingResult(
                    text: snippet.text,
                    appliedStages: stages + ["snippets", "snippet"],
                    firedDictionaryEntryIDs: dictIDs,
                    expandedSnippetIDs: snippet.ids
                )
            }
            if snippet.changed {
                stages.append("snippets")
                stages.append("snippet")
                text = snippet.text
                tokens = snippet.tokens
                snippetIDs = snippet.ids
            }
        }

        let firstFrozen = tokens.first(where: { $0.isWord }).map { $0.fromDictionary || $0.frozen } ?? false
        let beforeSmart = text

        if options.smartFormatting {
            let styled = SmartFormatting.apply(
                text,
                style: context.style,
                appAware: options.appAwareStyle,
                precedingText: context.precedingText,
                firstWordFromDictionary: firstFrozen,
                english: english
            )
            text = styled.text
            for stage in styled.stages where !stages.contains(stage) {
                stages.append(stage)
            }
            if text != beforeSmart, !stages.contains("smart-formatting") {
                stages.append("smart-formatting")
            }
        } else {
            text = SmartFormatting.applyPrecedingOnly(
                text,
                precedingText: context.precedingText,
                firstWordFromDictionary: firstFrozen,
                style: options.appAwareStyle ? context.style : .standard
            )
        }

        return FormattingResult(
            text: text,
            appliedStages: stages,
            firedDictionaryEntryIDs: dictIDs,
            expandedSnippetIDs: snippetIDs
        )
    }

    /// Compatibility overload used by tests that pass options separately from context.
    public func format(
        _ raw: String,
        options: FormattingOptions = FormattingOptions(),
        context: FormattingContext = FormattingContext()
    ) -> FormattingResult {
        var ctx = context
        ctx.options = options
        if !options.dictionary.isEmpty { ctx.dictionary = options.dictionary }
        if !options.snippets.isEmpty { ctx.snippets = options.snippets }
        return format(raw, context: ctx)
    }

    private struct DictOutcome {
        var tokens: [Token]
        var fired: [UUID]
    }

    private func applyDictionary(tokens: [Token], entries: [DictionaryEntry]) -> DictOutcome {
        let sorted = entries
            .filter { !$0.spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                Tokenizer.punctuationStrippedLower($0.spoken).split(separator: " ").count
                    > Tokenizer.punctuationStrippedLower($1.spoken).split(separator: " ").count
            }

        var tokens = tokens
        var fired: [UUID] = []
        var firedSet = Set<UUID>()
        var i = 0
        while i < tokens.count {
            if !tokens[i].isWord {
                i += 1
                continue
            }
            var matched = false
            for entry in sorted {
                let spokenWords = Tokenizer.tokenize(entry.spoken).filter(\.isWord).map(\.lower)
                guard !spokenWords.isEmpty else { continue }
                guard i + spokenWords.count <= tokens.count else { continue }
                var ok = true
                for (offset, word) in spokenWords.enumerated() {
                    if !tokens[i + offset].isWord || tokens[i + offset].lower != word {
                        ok = false
                        break
                    }
                }
                if !ok { continue }

                var written = entry.written
                if Tokenizer.isSentenceStart(tokens: tokens, index: i),
                   written == written.lowercased(),
                   let first = written.first,
                   first.isLetter {
                    written = Tokenizer.capitalizeFirstLetter(written)
                }
                var injected = Tokenizer.tokenize(written)
                if injected.isEmpty {
                    injected = [Token(
                        core: written,
                        trailing: tokens[i + spokenWords.count - 1].trailing,
                        spaceBefore: tokens[i].spaceBefore,
                        frozen: true,
                        fromDictionary: true
                    )]
                } else {
                    injected[0].spaceBefore = tokens[i].spaceBefore
                    injected[0].leading = tokens[i].leading + injected[0].leading
                    let lastSpoken = tokens[i + spokenWords.count - 1]
                    if let last = injected.indices.last {
                        injected[last].trailing += lastSpoken.trailing
                    }
                    for idx in injected.indices {
                        injected[idx].frozen = true
                        injected[idx].fromDictionary = true
                    }
                }
                tokens.replaceSubrange(i..<(i + spokenWords.count), with: injected)
                if !firedSet.contains(entry.id) {
                    fired.append(entry.id)
                    firedSet.insert(entry.id)
                }
                i += injected.count
                matched = true
                break
            }
            if !matched { i += 1 }
        }
        return DictOutcome(tokens: tokens, fired: fired)
    }

    private struct SnippetOutcome {
        var text: String
        var tokens: [Token]
        var ids: [UUID]
        var changed: Bool
        var replacedEntire: Bool
    }

    private func applySnippets(text: String, tokens: [Token], snippets: [Snippet]) -> SnippetOutcome {
        let sorted = snippets
            .filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }

        let stripped = Tokenizer.punctuationStrippedLower(text)

        for snippet in sorted {
            let trigger = Tokenizer.punctuationStrippedLower(snippet.trigger)
            guard !trigger.isEmpty else { continue }
            let wholeMatches = stripped == trigger
                || stripped == "insert \(trigger)"
                || stripped == "paste \(trigger)"
                || stripped == "\(trigger) snippet"
            if wholeMatches {
                return SnippetOutcome(
                    text: snippet.expansion,
                    tokens: Tokenizer.tokenize(snippet.expansion),
                    ids: [snippet.id],
                    changed: true,
                    replacedEntire: true
                )
            }
        }

        var tokens = tokens
        var ids: [UUID] = []
        var changed = false
        var i = 0
        while i < tokens.count {
            if tokens[i].isWord, tokens[i].lower == "insert" || tokens[i].lower == "paste" {
                var did = false
                for snippet in sorted {
                    let triggerWords = Tokenizer.tokenize(snippet.trigger).filter(\.isWord).map(\.lower)
                    guard !triggerWords.isEmpty else { continue }
                    let start = i + 1
                    guard start + triggerWords.count <= tokens.count else { continue }
                    var ok = true
                    for (offset, word) in triggerWords.enumerated() {
                        if !tokens[start + offset].isWord || tokens[start + offset].lower != word {
                            ok = false
                            break
                        }
                    }
                    if !ok { continue }
                    var expansion = Tokenizer.tokenize(snippet.expansion)
                    if expansion.isEmpty {
                        expansion = [Token(core: snippet.expansion, spaceBefore: tokens[i].spaceBefore, frozen: true)]
                    } else {
                        expansion[0].spaceBefore = tokens[i].spaceBefore
                        for idx in expansion.indices { expansion[idx].frozen = true }
                    }
                    let end = start + triggerWords.count
                    tokens.replaceSubrange(i..<end, with: expansion)
                    ids.append(snippet.id)
                    changed = true
                    i += expansion.count
                    did = true
                    break
                }
                if !did { i += 1 }
            } else {
                i += 1
            }
        }

        return SnippetOutcome(
            text: Tokenizer.detokenize(tokens),
            tokens: tokens,
            ids: ids,
            changed: changed,
            replacedEntire: false
        )
    }
}
