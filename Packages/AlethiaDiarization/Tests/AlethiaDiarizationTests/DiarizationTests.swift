import XCTest
@testable import AlethiaDiarization
import AlethiaKnowledge
import AlethiaCore

final class EmbeddingMathTests: XCTestCase {
    func testCosineIdenticalIsOne() {
        let v: [Float] = [0.3, 0.4, 0]
        let n = EmbeddingMath.l2Normalize(v)
        XCTAssertEqual(EmbeddingMath.cosine(n, n), 1, accuracy: 1e-5)
    }

    func testEMAMovesTowardSample() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [1, 1, 1]
        let out = EmbeddingMath.ema(a, b, alpha: 0.5)
        XCTAssertEqual(out[0], 0.5, accuracy: 1e-6)
    }
}

final class DiarizationServiceTests: XCTestCase {
    func testMatchOrCreateReusesSpeaker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alethia-diar-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let gallery = try SpeakerGallery(store: store, matchThreshold: 0.5)
        let embedder = SpectralFingerprintEmbedder()
        let service = DiarizationService(gallery: gallery, embedder: embedder)

        let pcmA = tone(freq: 220, samples: 16_000, amp: 0.2)
        let pcmB = tone(freq: 220, samples: 16_000, amp: 0.21) // similar
        let out = try service.diarize(
            pcm: pcmA + pcmB,
            sampleRate: 16_000,
            transcripts: [
                (0, 1000, "hello from speaker one"),
                (1000, 2000, "still speaker one")
            ]
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].speakerID, out[1].speakerID)

        try gallery.rename(id: out[0].speakerID!, to: "Sam")
        let speakers = try store.allSpeakers()
        XCTAssertTrue(speakers.contains(where: { $0.displayName == "Sam" }))
    }

    func testECAPABridgeResolvesModelPathWiring() {
        let embedder = ECAPAGGMLEmbedder()
        // Model may be absent locally; path resolution should still be non-crashing.
        XCTAssertNoThrow(try embedder.embed(pcm: tone(freq: 440, samples: 2048, amp: 0.1), sampleRate: 16_000))
    }
}

private func tone(freq: Float, samples: Int, amp: Float, sampleRate: Float = 16_000) -> [Float] {
    (0..<samples).map { i in
        amp * sin(2 * Float.pi * freq * Float(i) / sampleRate)
    }
}
