import XCTest
@testable import AlethiaText

final class NumberFormattingTests: XCTestCase {
    let formatter = DictationFormatter()

    func smart(_ raw: String) -> String {
        formatter.format(
            raw,
            options: FormattingOptions(
                removeFillers: false,
                resolveSelfCorrections: false,
                applyVoiceCommands: false,
                smartFormatting: true,
                appAwareStyle: true
            ),
            context: FormattingContext(style: .chat)
        ).text
    }

    func testTwentyThree() {
        XCTAssertTrue(smart("twenty three").contains("23"))
    }

    func testOneHundredAndFive() {
        XCTAssertTrue(smart("one hundred and five").contains("105"))
    }

    func testYear() {
        XCTAssertTrue(smart("two thousand twenty six").contains("2026"))
    }

    func testDecimal() {
        XCTAssertTrue(smart("three point five").contains("3.5"))
    }

    func testMillionWithSeparators() {
        let t = smart("one million")
        XCTAssertTrue(t.contains("1,000,000") || t.contains("1000000"), t)
    }

    func testKeepSmallNumbersAsWords() {
        let t = smart("I have two cats")
        XCTAssertTrue(t.lowercased().contains("two"))
    }

    func testOneAsPronoun() {
        let t = smart("the red one")
        XCTAssertTrue(t.lowercased().contains("one"))
        XCTAssertFalse(t.contains("1"))
    }

    func testPercent() {
        let t = smart("twenty percent")
        XCTAssertTrue(t.contains("20%"))
    }

    func testDollars() {
        let t = smart("five dollars")
        XCTAssertTrue(t.contains("$5"))
    }

    func testDollarsAndCents() {
        let t = smart("two dollars and fifty cents")
        XCTAssertTrue(t.contains("$2.50") || t.contains("$2.5"))
    }

    func testEuros() {
        let t = smart("ten euros")
        XCTAssertTrue(t.contains("€10") || t.contains("€10"))
    }

    func testThreePM() {
        let t = smart("three pm")
        XCTAssertTrue(t.contains("3"))
        XCTAssertTrue(t.uppercased().contains("PM"))
    }

    func testThreeThirtyPM() {
        let t = smart("three thirty pm")
        XCTAssertTrue(t.contains("3:30"), t)
        XCTAssertTrue(t.uppercased().contains("PM"), t)
    }

    func testOrdinalCompound() {
        let t = smart("the twenty first day")
        XCTAssertTrue(t.contains("21st"))
    }

    func testThirdAloneStays() {
        let t = smart("coming in third")
        XCTAssertTrue(t.lowercased().contains("third"))
        XCTAssertFalse(t.contains("3rd"))
    }

    func testEmailSpoken() {
        let t = smart("john dot smith at gmail dot com")
        XCTAssertTrue(t.lowercased().contains("john.smith@gmail.com"), t)
    }

    func testURLSpoken() {
        let t = smart("example dot com slash docs")
        XCTAssertTrue(t.lowercased().contains("example.com/docs"), t)
    }

    func testWWW() {
        let t = smart("w w w dot example dot com")
        XCTAssertTrue(t.lowercased().contains("www."), t)
        XCTAssertTrue(t.lowercased().contains("example.com"), t)
    }

    func testFourFiveSixLeftAsWords() {
        let t = smart("four five six")
        XCTAssertTrue(t.lowercased().contains("four"), t)
        XCTAssertTrue(t.lowercased().contains("five"), t)
    }
}
