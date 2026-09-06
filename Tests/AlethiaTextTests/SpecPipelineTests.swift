import XCTest
import AlethiaCore
@testable import AlethiaText

final class SpecPipelineTests: XCTestCase {
    let formatter = DictationFormatter()

    func fmt(_ raw: String, style: AppStyle = .standard, options: FormattingOptions = FormattingOptions()) -> FormattingResult {
        formatter.format(raw, context: FormattingContext(style: style, options: options))
    }

    func testSelfCorrectionRequiredCases() {
        XCTAssertEqual(fmt("Send it on Tuesday, no, Wednesday.").text, "Send it on Wednesday.")
        XCTAssertEqual(fmt("Let's meet at 3, I mean 4 pm.").text, "Let's meet at 4 pm.")
        XCTAssertEqual(fmt("Call John, sorry, call Jane about the invoice.").text, "Call Jane about the invoice.")
        XCTAssertEqual(fmt("We need five, no wait, six chairs.").text, "We need six chairs.")
        XCTAssertEqual(fmt("The budget is 40k, actually 45k, for Q3.").text, "The budget is 45k for Q3.")
        XCTAssertEqual(fmt("No, I don't think that works.").text, "No, I don't think that works.")
        XCTAssertEqual(fmt("I mean it, we should ship.").text, "I mean it, we should ship.")
        XCTAssertEqual(fmt("Book the flight for Monday morning, or rather Tuesday morning.").text, "Book the flight for Tuesday morning.")
        XCTAssertEqual(
            fmt("Tell them the deadline is Friday. Scratch that. The deadline is Monday.").text,
            "The deadline is Monday."
        )
        let scratched = fmt("This is a test scratch that")
        XCTAssertEqual(scratched.text, "")
        XCTAssertTrue(scratched.wasScratched)
        XCTAssertEqual(fmt("Send the report to Anna, make that Anna and Ben.").text, "Send the report to Anna and Ben.")
        XCTAssertEqual(fmt("Actually, I think we should wait.").text, "Actually, I think we should wait.")
    }

    func testMustNotConvertNaturalPunctuationWords() {
        XCTAssertTrue(fmt("The trial period ends Friday.").text.lowercased().contains("period"), fmt("The trial period ends Friday.").text)
        XCTAssertTrue(fmt("Add a dash of salt.").text.lowercased().contains("dash"), fmt("Add a dash of salt.").text)
        XCTAssertTrue(fmt("Use a comma here.").text.lowercased().contains("comma"), fmt("Use a comma here.").text)
        XCTAssertTrue(fmt("The colon is inflamed.").text.lowercased().contains("colon"), fmt("The colon is inflamed.").text)
        XCTAssertEqual(fmt("No, thanks.").text, "No, thanks.")
        XCTAssertTrue(fmt("I mean it.").text.lowercased().contains("i mean it"))
        XCTAssertTrue(fmt("Actually, yes.").text.lowercased().contains("actually"))
        XCTAssertTrue(fmt("The number is 3, 4, 5.").text.contains("3, 4, 5") || fmt("The number is 3, 4, 5.").text.contains("3,4,5") == false)
        let numbers = fmt("The number is 3, 4, 5.")
        XCTAssertTrue(numbers.text.contains("3"))
        XCTAssertTrue(numbers.text.contains("4"))
        XCTAssertTrue(numbers.text.contains("5"))
    }

    func testVoiceCommandNewlinesAndPunct() {
        let nl = fmt("hello new line world", style: .chat, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false))
        XCTAssertTrue(nl.text.contains("\n"))
        XCTAssertTrue(nl.appliedStages.contains("voice-commands"), "\(nl.appliedStages) \(nl.text)")
        let para = fmt("hello new paragraph world", style: .chat, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false))
        XCTAssertTrue(para.text.contains("\n\n"))
        let q = fmt("are you there question mark", style: .chat, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false))
        XCTAssertTrue(q.text.contains("?"))
        let smiley = fmt("hello smiley face", style: .chat, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false))
        XCTAssertTrue(smiley.text.contains(":)"))
        let at = fmt("name at example dot com", style: .chat, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false, smartFormatting: false))
        XCTAssertTrue(at.text.lowercased().contains("name@example.com"), at.text)
        let hash = fmt("hashtag swift", style: .chat, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false))
        XCTAssertTrue(hash.text.lowercased().contains("#swift"))
        let caps = fmt("all caps hello there", style: .chat, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false))
        XCTAssertTrue(caps.text.contains("HELLO"))
        let cap = fmt("capital paris is nice", style: .standard, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false))
        XCTAssertTrue(cap.text.contains("Paris"))
        let glued = fmt("hello no space world", style: .chat, options: FormattingOptions(removeFillers: false, resolveSelfCorrections: false))
        XCTAssertTrue(glued.text.lowercased().contains("helloworld"))
    }

    func testFillersAndStutters() {
        let um = fmt("um hello there everyone")
        XCTAssertFalse(um.text.lowercased().contains("um"))
        XCTAssertTrue(um.appliedStages.contains("fillers"))
        let like = fmt("it was, like, really good")
        XCTAssertFalse(like.text.lowercased().contains("like"))
        let keepLike = fmt("I like it")
        XCTAssertTrue(keepLike.text.lowercased().contains("like"))
        let kind = fmt("a kind of tree")
        XCTAssertTrue(kind.text.lowercased().contains("kind of"))
        let stutter = fmt("the the cat sat")
        XCTAssertEqual(TextUtilities.words(in: stutter.text).filter { $0.lowercased() == "the" }.count, 1)
        let thatThat = fmt("I know that that is true")
        XCTAssertEqual(TextUtilities.words(in: thatThat.text).filter { $0.lowercased() == "that" }.count, 2)
        let so = fmt("So, we should go now")
        XCTAssertFalse(so.text.lowercased().hasPrefix("so,"))
        XCTAssertTrue(so.text.lowercased().contains("we should"))
        let youKnow = fmt("that was, you know, surprising")
        XCTAssertFalse(youKnow.text.lowercased().contains("you know"))
    }

    func testDictionaryAndSnippets() {
        let entry = DictionaryEntry(spoken: "alethia", written: "Alethia")
        let r = formatter.format(
            "i use alethia every day",
            context: FormattingContext(dictionary: [entry])
        )
        XCTAssertTrue(r.text.contains("Alethia"))
        XCTAssertEqual(r.firedDictionaryEntryIDs, [entry.id])
        XCTAssertTrue(r.appliedStages.contains("dictionary"))

        let short = DictionaryEntry(spoken: "git", written: "Git")
        let long = DictionaryEntry(spoken: "git hub", written: "GitHub")
        let r2 = formatter.format(
            "we use git hub",
            context: FormattingContext(dictionary: [short, long])
        )
        XCTAssertTrue(r2.text.contains("GitHub"))
        XCTAssertEqual(r2.firedDictionaryEntryIDs, [long.id])

        let snippet = Snippet(trigger: "my signature", expansion: "Best regards,\nAda")
        let r3 = formatter.format(
            "insert my signature",
            context: FormattingContext(
                options: FormattingOptions(
                    removeFillers: false,
                    resolveSelfCorrections: false,
                    applyVoiceCommands: false,
                    smartFormatting: false
                ),
                snippets: [snippet]
            )
        )
        XCTAssertEqual(r3.text, "Best regards,\nAda")
        XCTAssertEqual(r3.expandedSnippetIDs, [snippet.id])
        XCTAssertTrue(r3.appliedStages.contains("snippet"))

        let paste = formatter.format(
            "paste my signature",
            context: FormattingContext(
                options: FormattingOptions(smartFormatting: false),
                snippets: [snippet]
            )
        )
        XCTAssertEqual(paste.text, "Best regards,\nAda")

        let snipWord = formatter.format(
            "my signature snippet",
            context: FormattingContext(
                options: FormattingOptions(smartFormatting: false),
                snippets: [snippet]
            )
        )
        XCTAssertEqual(snipWord.text, "Best regards,\nAda")
    }

    func testAppAwareStyles() {
        let chat = fmt("hello there friend", style: .chat)
        XCTAssertFalse(chat.text.hasSuffix("."), chat.text)
        XCTAssertTrue(chat.appliedStages.contains("style:chat"), "\(chat.appliedStages)")
        let standard = fmt("hello there friend", style: .standard)
        XCTAssertTrue(standard.text.hasSuffix("."))
        let code = fmt("git commit message here", style: .code)
        XCTAssertFalse(code.text.hasPrefix("Git"))
        XCTAssertFalse(code.text.hasSuffix("."))
        XCTAssertTrue(code.appliedStages.contains("style:code"), "\(code.appliedStages) \(code.text)")
        let search = fmt("find the files please.", style: .search)
        XCTAssertFalse(search.text.hasSuffix("."))
        XCTAssertFalse(search.text.contains("\n"))
        let terminal = fmt("ls minus la files", style: .terminal)
        XCTAssertFalse(terminal.text.hasSuffix("."))
        let email = fmt("hello there friend", style: .email)
        XCTAssertTrue(email.text.hasSuffix("."))
        let notes = fmt("hello there friend", style: .notes)
        XCTAssertTrue(notes.text.hasSuffix("."))
    }

    func testStandaloneIAndSpacing() {
        let r = fmt("i think i'll go")
        XCTAssertTrue(r.text.contains("I think"))
        XCTAssertTrue(r.text.contains("I'll") || r.text.contains("I'LL"))
        XCTAssertTrue(r.appliedStages.contains("smart-formatting") || r.text.hasPrefix("I"))
    }

    func testOptionsFromSettings() {
        var settings = DictationSettings()
        settings.removeFillers = false
        settings.applyVoiceCommands = false
        let options = FormattingOptions(settings: settings)
        XCTAssertFalse(options.removeFillers)
        XCTAssertFalse(options.applyVoiceCommands)
        XCTAssertTrue(options.smartFormatting)
    }

    func testEmptyAndScratchStages() {
        XCTAssertEqual(fmt("   ").text, "")
        let r = fmt("scratch that")
        XCTAssertEqual(r.text, "")
        XCTAssertTrue(r.wasScratched)
    }

    func testTranscriptCleaner() {
        let cleaned = TranscriptCleaner.clean("um I I think we should wait")
        XCTAssertFalse(cleaned.lowercased().contains("um"))
        XCTAssertEqual(TextUtilities.words(in: cleaned).filter { $0.lowercased() == "i" }.count, 1)
        XCTAssertTrue(cleaned.lowercased().contains("think"))
        XCTAssertEqual(TranscriptCleaner.clean("   "), "")
    }
}
