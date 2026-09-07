import XCTest
import AlethiaCore
@testable import AlethiaAudio

final class AudioMixerTests: XCTestCase {
    func testMicOnlyPassThroughInHops() {
        let mixer = AudioMixer(sampleRate: 1000, hopMilliseconds: 100, includesSystemAudio: false)
        var chunks: [MixedChunk] = []
        mixer.onChunk = { chunks.append($0) }

        mixer.push([Float](repeating: 0.5, count: 250), from: .microphone)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].samples.count, 100)
        XCTAssertEqual(chunks[1].startSample, 100)
        XCTAssertEqual(chunks[0].microphoneRMS, 0.5, accuracy: 1e-5)
        XCTAssertEqual(chunks[0].systemRMS, 0)

        mixer.push([Float](repeating: 0.5, count: 100), from: .system) // ignored
        XCTAssertEqual(chunks.count, 2)

        mixer.flush()
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[2].samples.count, 50)
        XCTAssertEqual(mixer.emittedSamples, 250)
    }

    func testSumsBothSourcesOnSharedTimeline() {
        let mixer = AudioMixer(sampleRate: 1000, hopMilliseconds: 100, includesSystemAudio: true)
        var chunks: [MixedChunk] = []
        mixer.onChunk = { chunks.append($0) }

        mixer.push([Float](repeating: 0.2, count: 100), from: .microphone)
        XCTAssertTrue(chunks.isEmpty, "waits for the other source")
        mixer.push([Float](repeating: 0.3, count: 100), from: .system)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples[10], 0.5, accuracy: 1e-5)
        XCTAssertEqual(chunks[0].microphoneRMS, 0.2, accuracy: 1e-5)
        XCTAssertEqual(chunks[0].systemRMS, 0.3, accuracy: 1e-5)
    }

    func testPadsStalledSourceAfterMaxLag() {
        let mixer = AudioMixer(sampleRate: 1000, hopMilliseconds: 100, includesSystemAudio: true, maxLagMilliseconds: 300)
        var chunks: [MixedChunk] = []
        mixer.onChunk = { chunks.append($0) }

        mixer.push([Float](repeating: 0.4, count: 299), from: .microphone)
        XCTAssertTrue(chunks.isEmpty)
        mixer.push([Float](repeating: 0.4, count: 1), from: .microphone)
        XCTAssertEqual(chunks.count, 1, "system stalled beyond max lag → emit with silence")
        XCTAssertEqual(chunks[0].samples.count, 100)
        XCTAssertEqual(chunks[0].systemRMS, 0)
        XCTAssertEqual(chunks[0].samples[0], 0.4, accuracy: 1e-5)

        // System comes back: the remaining 200 mic samples pair up normally.
        mixer.push([Float](repeating: 0.1, count: 200), from: .system)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[2].samples[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(mixer.emittedSamples, 300)
    }

    func testFlushDrainsEverything() {
        let mixer = AudioMixer(sampleRate: 1000, hopMilliseconds: 100, includesSystemAudio: true)
        var chunks: [MixedChunk] = []
        mixer.onChunk = { chunks.append($0) }
        mixer.push([Float](repeating: 0.1, count: 130), from: .microphone)
        mixer.push([Float](repeating: 0.1, count: 40), from: .system)
        mixer.flush()
        XCTAssertEqual(mixer.emittedSamples, 130)
        XCTAssertEqual(chunks.map(\.samples.count).reduce(0, +), 130)
        let timeline = mixer.activityTimeline
        XCTAssertEqual(timeline.first?.startMs, 0)
        XCTAssertEqual(timeline.last?.endMs, 130)
    }

    func testSoftClipStaysInRange() {
        for x: Float in [-3, -1.5, -1, -0.5, 0, 0.5, 0.79, 0.81, 1, 1.5, 3] {
            let y = AudioMixer.softClip(x)
            XCTAssertLessThanOrEqual(abs(y), 1.0001)
            if abs(x) <= 0.8 { XCTAssertEqual(y, x) }
        }
        XCTAssertGreaterThan(AudioMixer.softClip(2), AudioMixer.softClip(1))
    }

    func testMicrophoneDominance() {
        let frames = [
            SourceActivityFrame(startMs: 0, endMs: 100, microphoneRMS: 0.2, systemRMS: 0.01),
            SourceActivityFrame(startMs: 100, endMs: 200, microphoneRMS: 0.25, systemRMS: 0.02),
            SourceActivityFrame(startMs: 200, endMs: 300, microphoneRMS: 0.01, systemRMS: 0.3),
            SourceActivityFrame(startMs: 300, endMs: 400, microphoneRMS: 0.001, systemRMS: 0.001),
        ]
        XCTAssertEqual(frames.microphoneDominates(startMs: 0, endMs: 200), true)
        XCTAssertEqual(frames.microphoneDominates(startMs: 200, endMs: 300), false)
        XCTAssertNil(frames.microphoneDominates(startMs: 300, endMs: 400))
        XCTAssertNil(frames.microphoneDominates(startMs: 900, endMs: 1000))
    }

    func testWAVFileWriterStreamsAndPatchesHeader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alethia-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("test.wav")
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        let tone: [Float] = (0..<48_000).map { sin(Float($0) * 0.01) * 0.3 }
        try writer.append(Array(tone[0..<20_000]))
        try writer.append(Array(tone[20_000...]))
        XCTAssertEqual(writer.framesWritten, 48_000)
        XCTAssertEqual(writer.durationMs, 3000)
        try writer.close()

        let decoded = try WAVCodec.read(url)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertEqual(decoded.samples.count, 48_000)
        XCTAssertEqual(decoded.samples[1000], tone[1000], accuracy: 1e-4)

        // Simulate a crash: corrupt header sizes, then repair.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVCodec.header(sampleRate: 16_000, dataBytes: 0))
        try handle.close()
        try WAVFileWriter.repairHeader(at: url, sampleRate: 16_000)
        XCTAssertEqual(try WAVCodec.read(url).samples.count, 48_000)
    }

    func testLevelMeter() {
        var meter = AudioLevelMeter()
        XCTAssertEqual(meter.update(rms: 0), 0, accuracy: 1e-6)
        let loud = meter.update(rms: 0.5)
        XCTAssertGreaterThan(loud, 0.3)
        let decayed = meter.update(rms: 0)
        XCTAssertLessThan(decayed, loud)
    }
}
