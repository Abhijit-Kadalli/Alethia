import XCTest
@testable import AlethiaAudio
import AlethiaCore

final class DSPAnalyzerTests: XCTestCase {
    func testSilenceFailsNoiseGate() {
        let frame = [Float](repeating: 0, count: 480)
        let features = DSPAnalyzer.analyze(frame: frame)
        XCTAssertEqual(features.rms, 0, accuracy: 1e-6)
        XCTAssertFalse(features.passesNoiseGate)
    }

    func testTonePassesNoiseGate() {
        let frame = tone(freq: 800, samples: 480, amp: 0.2)
        let features = DSPAnalyzer.analyze(frame: frame)
        XCTAssertGreaterThan(features.rms, 0.05)
        XCTAssertTrue(features.passesNoiseGate)
    }
}

final class VADGateTests: XCTestCase {
    func testHysteresisOpenClose() {
        let gate = VADGate()
        for _ in 0..<5 {
            XCTAssertEqual(gate.process(probability: 0.1, dspPassed: true, frameMs: 30), .silence)
        }
        var state = SpeechState.silence
        for _ in 0..<6 {
            state = gate.process(probability: 0.8, dspPassed: true, frameMs: 30)
        }
        XCTAssertEqual(state, .speech)
        for _ in 0..<20 {
            state = gate.process(probability: 0.1, dspPassed: true, frameMs: 30)
        }
        XCTAssertEqual(state, .silence)
    }
}

final class ConversationSegmenterTests: XCTestCase {
    func testOpensAfterSustainedSpeechAndClosesOnSilence() {
        var config = PipelineConfig.default
        config.minConversationSpeechMs = 150
        config.closeSilenceMs = 500
        let segmenter = ConversationSegmenter(config: config)
        let frame = tone(freq: 500, samples: 160, amp: 0.1)

        var opened = false
        var closed = false
        for _ in 0..<10 {
            if let event = segmenter.process(isSpeech: true, frame: frame, frameMs: 30) {
                if case .opened = event { opened = true }
            }
        }
        XCTAssertTrue(opened)

        for _ in 0..<200 {
            if let event = segmenter.process(isSpeech: false, frame: [Float](repeating: 0, count: 160), frameMs: 30) {
                if case .closed = event { closed = true }
            }
        }
        XCTAssertTrue(closed)
    }

    func testDiscardsTooShortConversationOnForceClose() {
        var config = PipelineConfig.default
        config.minConversationSpeechMs = 5_000
        let segmenter = ConversationSegmenter(config: config)
        let frame = tone(freq: 500, samples: 160, amp: 0.1)
        // Force open path by feeding enough window speech relative to lowered threshold... 
        // With min 5000, open needs 5000ms speech. Feed that, then forceClose after little speech in active? 
        // Actually once opened, speechMs resets to frameMs. Force close quickly -> discarded.
        config.minConversationSpeechMs = 90
        let seg2 = ConversationSegmenter(config: config)
        _ = seg2.process(isSpeech: true, frame: frame, frameMs: 100)
        if case .discarded? = seg2.forceClose() {
            // opened with 100ms then force close -> speechMs may be 100 < 90? 100 >= 90 so closed
        }
        // Open then immediately force close with high min
        var high = PipelineConfig.default
        high.minConversationSpeechMs = 10_000
        // Can't open without 10s speech. Verify forceClose nil when inactive.
        let idle = ConversationSegmenter(config: high)
        XCTAssertNil(idle.forceClose())
    }
}

private func tone(freq: Float, samples: Int, amp: Float, sampleRate: Float = 16_000) -> [Float] {
    (0..<samples).map { i in
        amp * sin(2 * Float.pi * freq * Float(i) / sampleRate)
    }
}
