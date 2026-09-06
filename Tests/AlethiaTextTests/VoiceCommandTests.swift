import XCTest
@testable import AlethiaText

final class VoiceCommandTests: XCTestCase {
    let formatter = DictationFormatter()

    func cmd(_ raw: String) -> String {
        formatter.format(
            raw,
            options: FormattingOptions(
                removeFillers: false,
                resolveSelfCorrections: false,
                applyVoiceCommands: true,
                smartFormatting: true,
                appAwareStyle: false
            ),
            context: FormattingContext(style: .standard)
        ).text
    }

    func testPeriod() {
        let t = cmd("hello period")
        XCTAssertTrue(t.contains("."), t)
        XCTAssertFalse(t.lowercased().contains("period"), t)
    }

    func testThePeriodNotConverted() {
        let t = cmd("the period is over")
        XCTAssertTrue(t.lowercased().contains("period"))
    }

    func testComma() {
        let t = cmd("apples comma")
        XCTAssertTrue(t.contains(","), t)
        XCTAssertFalse(t.lowercased().contains("comma"), t)
    }

    func testQuestionMark() {
        let t = cmd("are you there question mark")
        XCTAssertTrue(t.contains("?"))
    }

    func testNewLine() {
        let t = cmd("hello new line world")
        XCTAssertTrue(t.contains("\n"))
    }

    func testNewParagraph() {
        let t = cmd("hello new paragraph world")
        XCTAssertTrue(t.contains("\n\n"))
    }

    func testHyphenJoins() {
        let t = cmd("well hyphen known")
        XCTAssertTrue(t.lowercased().contains("well-known"), t)
    }

    func testDashAtEnd() {
        let t = cmd("hello dash")
        XCTAssertTrue(t.contains("-"))
        XCTAssertFalse(t.lowercased().contains("dash"))
    }

    func testQuotes() {
        let t = cmd("he said open quote hello close quote")
        XCTAssertTrue(t.contains("\""))
    }

    func testParens() {
        let t = cmd("see open paren details close paren")
        XCTAssertTrue(t.contains("("))
        XCTAssertTrue(t.contains(")"))
    }

    func testAtSign() {
        let t = cmd("user at sign example")
        XCTAssertTrue(t.contains("@"))
    }

    func testHashtag() {
        let t = cmd("hashtag swift")
        XCTAssertTrue(t.contains("#swift") || t.contains("#Swift"))
    }

    func testSmiley() {
        let t = cmd("hello smiley face")
        XCTAssertTrue(t.contains(":)"))
    }

    func testAllCaps() {
        let t = cmd("all caps hello there")
        XCTAssertTrue(t.contains("HELLO") || t.contains("Hello"))
    }

    func testCapital() {
        let t = cmd("capital paris is nice")
        XCTAssertTrue(t.contains("Paris"))
    }

    func testNoSpace() {
        let t = cmd("hello no space world")
        XCTAssertTrue(t.lowercased().contains("helloworld"))
    }

    func testEllipsis() {
        let t = cmd("wait ellipsis")
        XCTAssertTrue(t.contains("…") || t.contains("..."))
    }

    func testCapsLockSpan() {
        let t = cmd("caps lock on hello world caps lock off now")
        XCTAssertTrue(t.contains("HELLO") && t.contains("WORLD"))
    }

    func testSlash() {
        let t = cmd("usr slash bin")
        XCTAssertTrue(t.contains("/"))
    }
}
