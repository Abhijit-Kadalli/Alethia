import XCTest
@testable import AlethiaText

final class CorrectionLearnerTests: XCTestCase {
    let learner = CorrectionLearner()

    func testNameCapitalization() {
        let s = learner.suggestions(inserted: "send it to john", edited: "send it to Jon")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].spoken, "john")
        XCTAssertEqual(s[0].written, "Jon")
    }

    func testAbbreviation() {
        let s = learner.suggestions(inserted: "we use kubernetes", edited: "we use k8s")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].spoken, "kubernetes")
        XCTAssertEqual(s[0].written, "k8s")
    }

    func testPunctuationOnlyGivesNone() {
        let s = learner.suggestions(inserted: "hello world", edited: "hello world.")
        XCTAssertTrue(s.isEmpty)
    }

    func testIdenticalGivesNone() {
        XCTAssertTrue(learner.suggestions(inserted: "hello world", edited: "hello world").isEmpty)
    }

    func testEmptyWrittenIgnored() {
        let s = learner.suggestions(inserted: "hello world", edited: "hello")
        XCTAssertTrue(s.filter { $0.written.isEmpty }.isEmpty)
    }

    func testMultiWordShortSubstitution() {
        let s = learner.suggestions(inserted: "see you later", edited: "see ya later")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].spoken, "you")
        XCTAssertEqual(s[0].written, "ya")
    }
}
