import XCTest
@testable import AlethiaText

final class LearnedCorrectionTests: XCTestCase {
    func testCaseFixMidSentence() {
        let c = LearnedCorrectionDetector.candidates(
            inserted: "I use alethea daily.",
            edited: "I use Alethia daily."
        )
        XCTAssertEqual(c, [CorrectionCandidate(spoken: "alethea", written: "Alethia")])
    }

    func testMultiTokenSpokenToShortWritten() {
        let c = LearnedCorrectionDetector.candidates(
            inserted: "deploy to k eight s",
            edited: "deploy to k8s"
        )
        XCTAssertEqual(c, [CorrectionCandidate(spoken: "k eight s", written: "k8s")])
    }

    func testFullRewriteIsIgnored() {
        let c = LearnedCorrectionDetector.candidates(
            inserted: "let us ship the beta next week",
            edited: "completely different words appear here now"
        )
        XCTAssertEqual(c, [])
    }

    func testAddedPeriodIgnored() {
        let c = LearnedCorrectionDetector.candidates(
            inserted: "I use Alethia daily",
            edited: "I use Alethia daily."
        )
        XCTAssertEqual(c, [])
    }

    func testSentenceStartCaseIgnored() {
        let c = LearnedCorrectionDetector.candidates(
            inserted: "hello there friends",
            edited: "Hello there friends"
        )
        XCTAssertEqual(c, [])
    }

    func testTwoTokenSubstitution() {
        let c = LearnedCorrectionDetector.candidates(
            inserted: "see you git hub tomorrow",
            edited: "see you GitHub tomorrow"
        )
        XCTAssertEqual(c.first?.spoken, "git hub")
        XCTAssertEqual(c.first?.written, "GitHub")
    }
}
