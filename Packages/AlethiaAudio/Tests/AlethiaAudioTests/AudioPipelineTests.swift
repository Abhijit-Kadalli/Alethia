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

    func testTonePassesAbsoluteGate() {
        let frame = tone(freq: 800, samples: 480, amp: 0.2)
        let features = DSPAnalyzer.analyze(frame: frame)
        XCTAssertGreaterThan(features.rms, 0.05)
        XCTAssertTrue(features.passesNoiseGate)
    }

    func testBinwiseSFMToneLowerThanNoise() {
        let t = DSPAnalyzer.analyze(frame: tone(freq: 800, samples: 480, amp: 0.2))
        let n = DSPAnalyzer.analyze(frame: whiteNoise(samples: 480, amp: 0.2))
        XCTAssertLessThan(t.spectralFlatness, n.spectralFlatness)
    }
}

final class ClassicalSpeechScorerTests: XCTestCase {
    func testMaleF0HighProbability() {
        let scorer = ClassicalSpeechScorer()
        for _ in 0..<20 {
            _ = scorer.assess(frame: whiteNoise(samples: 480, amp: 0.002))
        }
        let a = scorer.assess(frame: tone(freq: 120, samples: 480, amp: 0.12))
        XCTAssertTrue(a.energyPassed)
        XCTAssertGreaterThanOrEqual(a.probability, 0.50)
    }

    func testWhiteNoiseCappedBelowOpen() {
        let scorer = ClassicalSpeechScorer()
        var last = scorer.assess(frame: whiteNoise(samples: 480, amp: 0.08))
        for _ in 0..<30 {
            last = scorer.assess(frame: whiteNoise(samples: 480, amp: 0.08))
        }
        XCTAssertLessThanOrEqual(last.probability, 0.28)
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
        var high = PipelineConfig.default
        high.minConversationSpeechMs = 10_000
        let idle = ConversationSegmenter(config: high)
        XCTAssertNil(idle.forceClose())
    }
}

private func tone(freq: Float, samples: Int, amp: Float, sampleRate: Float = 16_000) -> [Float] {
    (0..<samples).map { i in
        amp * sin(2 * Float.pi * freq * Float(i) / sampleRate)
    }
}

private func whiteNoise(samples: Int, amp: Float) -> [Float] {
    (0..<samples).map { _ in amp * Float.random(in: -1...1) }
}
