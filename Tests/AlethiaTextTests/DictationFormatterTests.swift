import XCTest
@testable import AlethiaText
import AlethiaCore

final class DictationFormatterTests: XCTestCase {
    let formatter = DictationFormatter()

    func format(
        _ raw: String,
        options: FormattingOptions = FormattingOptions(),
        context: FormattingContext = FormattingContext()
    ) -> FormattedText {
        formatter.format(raw, options: options, context: context)
    }

    func testNormalizeWhitespaceAndSpaceBeforePunct() {
        let result = format("  hello   world  ,  there  ")
        XCTAssertTrue(result.text.contains("world,"))
        XCTAssertFalse(result.text.contains("  "))
    }

    func testFillerUmRemoved() {
        let result = format("um hello umm there uh")
        XCTAssertFalse(result.text.lowercased().contains("um"))
        XCTAssertTrue(result.text.lowercased().contains("hello"))
        XCTAssertTrue(result.appliedStages.contains("fillers"))
    }

    func testMhmKeptAsAnswer() {
        let result = format("mhm that is fine")
        XCTAssertTrue(result.text.lowercased().contains("mhm"))
        XCTAssertTrue(result.text.lowercased().contains("that is fine"))
    }

    func testMmHmmKeptAsAnswer() {
        let result = format("mm-hmm we should go now")
        XCTAssertTrue(result.text.lowercased().contains("mm-hmm") || result.text.lowercased().contains("mmhmm"))
        XCTAssertTrue(result.text.lowercased().contains("we should"))
    }

    func testHuhNotTreatedAsRequiredFiller() {
        let result = format("huh that is odd enough")
        XCTAssertTrue(result.text.lowercased().contains("that is odd"))
    }

    func testCurlyQuotesNormalized() {
        let result = format("\u{201C}hello\u{201D} there friend")
        XCTAssertFalse(result.text.contains("\u{201C}"))
        XCTAssertFalse(result.text.contains("\u{201D}"))
        XCTAssertTrue(result.text.contains("\""))
    }

    func testLikeInILikeItPreserved() {
        let result = format("I like it")
        XCTAssertTrue(result.text.lowercased().contains("like"))
    }

    func testCommaSetOffLikeRemoved() {
        let result = format("it was, like, really good")
        XCTAssertFalse(result.text.lowercased().contains("like"))
        XCTAssertTrue(result.text.lowercased().contains("really"))
    }

    func testKindOfTreePreserved() {
        let result = format("a kind of tree")
        XCTAssertTrue(result.text.lowercased().contains("kind of"))
    }

    func testStutterTheThe() {
        let result = format("the the cat sat")
        let words = TextUtilities.words(in: result.text).map { $0.lowercased() }
        XCTAssertEqual(words.filter { $0 == "the" }.count, 1)
    }

    func testSelfCorrectionNoWait() {
        let result = format("send it to John, no wait, to Sarah tomorrow")
        XCTAssertTrue(result.text.lowercased().contains("sarah"))
        XCTAssertFalse(result.text.lowercased().contains("john"))
        XCTAssertTrue(result.text.lowercased().contains("tomorrow"))
        XCTAssertTrue(result.appliedStages.contains("self-correction"))
    }

    func testSelfCorrectionIMean() {
        let result = format("meet at three, I mean four pm")
        XCTAssertTrue(result.text.contains("4"))
        XCTAssertTrue(result.text.uppercased().contains("PM"))
        XCTAssertFalse(result.text.lowercased().contains("three"))
    }

    func testSelfCorrectionActuallyTuesday() {
        let result = format("I'll call him on Monday, actually Tuesday")
        XCTAssertTrue(result.text.lowercased().contains("tuesday"))
        XCTAssertFalse(result.text.lowercased().contains("monday"))
    }

    func testSelfCorrectionScratchThatRestatement() {
        let result = format("let's ship it Friday scratch that let's ship it next week")
        XCTAssertTrue(result.text.lowercased().contains("next week"))
        XCTAssertFalse(result.text.lowercased().contains("friday"))
    }

    func testSelfCorrectionSorry() {
        let result = format("the red one, sorry, the blue one")
        XCTAssertTrue(result.text.lowercased().contains("blue"))
        XCTAssertFalse(result.text.lowercased().contains("red"))
    }

    func testActuallyNotACorrection() {
        let result = format("I actually like it")
        XCTAssertTrue(result.text.lowercased().contains("actually"))
        XCTAssertTrue(result.text.lowercased().contains("like"))
    }

    func testScratchThatAloneIsEmpty() {
        let result = format("scratch that")
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.text, "")
    }

    func testDictionaryReplacement() {
        let entry = DictionaryEntry(spoken: "alethia", written: "Alethia")
        let options = FormattingOptions(dictionary: [entry])
        let result = format("i use alethia every day", options: options)
        XCTAssertTrue(result.text.contains("Alethia"))
        XCTAssertEqual(result.usedDictionaryIDs, [entry.id])
        XCTAssertTrue(result.appliedStages.contains("dictionary"))
    }

    func testDictionaryLongestFirst() {
        let short = DictionaryEntry(spoken: "git", written: "Git")
        let long = DictionaryEntry(spoken: "git hub", written: "GitHub")
        let options = FormattingOptions(dictionary: [short, long])
        let result = format("we use git hub", options: options)
        XCTAssertTrue(result.text.contains("GitHub"))
        XCTAssertEqual(result.usedDictionaryIDs, [long.id])
    }

    func testSnippetWholeTrigger() {
        let snippet = Snippet(trigger: "my signature", expansion: "Best regards,\nAda")
        let options = FormattingOptions(
            removeFillers: false,
            resolveSelfCorrections: false,
            applyVoiceCommands: false,
            smartFormatting: false,
            snippets: [snippet]
        )
        let result = format("insert my signature", options: options)
        XCTAssertEqual(result.text, "Best regards,\nAda")
        XCTAssertEqual(result.usedSnippetIDs, [snippet.id])
    }

    func testSnippetInlineInsert() {
        let snippet = Snippet(trigger: "sig", expansion: "-- Ada --")
        let options = FormattingOptions(smartFormatting: false, snippets: [snippet])
        let result = format("hello insert sig thanks", options: options)
        XCTAssertTrue(result.text.contains("-- Ada --"))
        XCTAssertEqual(result.usedSnippetIDs, [snippet.id])
    }

    func testChatStyleNoTrailingPeriod() {
        let result = format(
            "hello there friend",
            context: FormattingContext(style: .chat)
        )
        XCTAssertFalse(result.text.hasSuffix("."))
    }

    func testStandardStyleAddsTrailingPeriod() {
        let result = format(
            "hello there friend",
            context: FormattingContext(style: .standard)
        )
        XCTAssertTrue(result.text.hasSuffix("."))
    }

    func testCodeStyleNoAutoCapitalize() {
        let result = format(
            "git commit message here",
            context: FormattingContext(style: .code)
        )
        XCTAssertFalse(result.text.hasPrefix("Git"), result.text)
        XCTAssertFalse(result.text.hasSuffix("."), result.text)
    }

    func testSearchStyleStripsPunctuation() {
        let result = format(
            "find the files please",
            context: FormattingContext(style: .search)
        )
        XCTAssertFalse(result.text.hasSuffix("."))
        XCTAssertFalse(result.text.contains("\n"))
    }

    func testPrecedingTextAddsSpaceAndLowercases() {
        let result = format(
            "and then we left",
            context: FormattingContext(style: .standard, precedingText: "Hello there")
        )
        XCTAssertTrue(result.text.hasPrefix(" "))
        XCTAssertTrue(result.text.dropFirst().hasPrefix("and"))
    }

    func testPrecedingTextAfterPeriodCapitalizes() {
        let result = format(
            "we should go",
            context: FormattingContext(style: .standard, precedingText: "Hello.")
        )
        XCTAssertTrue(result.text.hasPrefix(" "))
        XCTAssertTrue(result.text.drop(while: { $0 == " " }).hasPrefix("We"))
    }

    func testPrecedingTextAfterWhitespaceNoExtraSpace() {
        let result = format(
            "next words here",
            context: FormattingContext(precedingText: "Hello ")
        )
        XCTAssertFalse(result.text.hasPrefix(" "))
    }

    func testNonEnglishSkipsFillers() {
        let result = format(
            "um hola amigos queridos",
            context: FormattingContext(language: "es")
        )
        XCTAssertTrue(result.text.lowercased().contains("um"))
    }

    func testFrenchGetsCapitalizationNotFillerRemoval() {
        let result = format(
            "bonjour je m'appelle jean aujourd'hui",
            context: FormattingContext(language: "fr")
        )
        XCTAssertTrue(result.text.hasPrefix("B") || result.text.lowercased().hasPrefix("bonjour"))
        XCTAssertTrue(result.text.lowercased().contains("bonjour"))
    }

    func testStandaloneICapitalized() {
        let result = format("i think i'll go")
        XCTAssertTrue(result.text.contains("I think"))
        XCTAssertTrue(result.text.contains("I'll") || result.text.contains("I'LL"))
    }

    func testAppliedStagesOnlyWhenChanged() {
        let result = format("hello")
        XCTAssertFalse(result.appliedStages.contains("fillers"), "\(result.appliedStages) \(result.text)")
        XCTAssertFalse(result.appliedStages.contains("self-correction"), "\(result.appliedStages)")
    }

    func testEmptyInput() {
        let result = format("   ")
        XCTAssertTrue(result.isEmpty)
    }

    func testAppStyleInferSlack() {
        XCTAssertEqual(AppStyle.infer(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppStyle.infer(bundleID: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(AppStyle.infer(bundleID: "com.jetbrains.intellij"), .code)
        XCTAssertEqual(AppStyle.infer(bundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(AppStyle.infer(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AppStyle.infer(bundleID: "md.obsidian"), .notes)
        XCTAssertEqual(AppStyle.infer(bundleID: "com.raycast.macos"), .search)
        XCTAssertEqual(AppStyle.infer(bundleID: "com.google.Chrome"), .standard)
        XCTAssertEqual(AppStyle.infer(bundleID: nil), .standard)
        XCTAssertEqual(AppStyle.chat.displayName, "Chat")
    }

    func testYouKnowRemovedWhenSetOff() {
        let result = format("that was, you know, surprising")
        XCTAssertFalse(result.text.lowercased().contains("you know"))
        XCTAssertTrue(result.text.lowercased().contains("surprising"))
    }

    func testDeleteThatCommand() {
        let options = FormattingOptions(removeFillers: false, resolveSelfCorrections: false)
        let result = format("please ignore this delete that keep going now", options: options)
        XCTAssertTrue(result.text.lowercased().contains("keep going"))
        XCTAssertFalse(result.text.lowercased().contains("ignore this"))
    }

    func testNumeralCommand() {
        let options = FormattingOptions(removeFillers: false, resolveSelfCorrections: false)
        let result = format("numeral five apples", options: options, context: FormattingContext(style: .chat))
        XCTAssertTrue(result.text.contains("5"), result.text)
    }

    func testTextUtilitiesSentencesAndTruncate() {
        let sents = TextUtilities.sentences(in: "Hello there. How are you? Fine")
        XCTAssertEqual(sents.count, 3)
        XCTAssertEqual(TextUtilities.words(in: "Hello, world!").count, 2)
        XCTAssertEqual(TextUtilities.capitalizingFirstLetter("hello"), "Hello")
        let long = String(repeating: "a", count: 50)
        let t = TextUtilities.truncate(long, to: 21, keepingEnds: true)
        XCTAssertTrue(t.contains("[…]"))
        XCTAssertEqual(t.count, 21)
    }
}
