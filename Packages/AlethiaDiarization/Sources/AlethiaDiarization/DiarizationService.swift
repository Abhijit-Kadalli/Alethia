import Foundation
import AlethiaCore
import AlethiaKnowledge

public struct DiarizedUtterance: Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var speakerLabel: String
    public var speakerID: UUID?
    public var embedding: [Float]

    public init(
        startMs: Int,
        endMs: Int,
        text: String,
        speakerLabel: String,
        speakerID: UUID? = nil,
        embedding: [Float] = []
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.speakerLabel = speakerLabel
        self.speakerID = speakerID
        self.embedding = embedding
    }
}

public enum EmbeddingMath {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? dot / denom : -1
    }

    public static func ema(_ previous: [Float], _ sample: [Float], alpha: Float = 0.15) -> [Float] {
        guard previous.count == sample.count, !previous.isEmpty else { return sample }
        return zip(previous, sample).map { (1 - alpha) * $0 + alpha * $1 }
    }
}

/// Deterministic pseudo-embedding for scaffolding until ECAPA GGML is wired.
public struct PseudoECAPA: Sendable {
    public init() {}

    public func embed(pcm: [Float]) -> [Float] {
        var emb = [Float](repeating: 0, count: 192)
        guard !pcm.isEmpty else { return emb }
        let step = max(pcm.count / 192, 1)
        for i in 0..<192 {
            let start = min(i * step, pcm.count - 1)
            let end = min(start + step, pcm.count)
            var sum: Float = 0
            for j in start..<end { sum += abs(pcm[j]) }
            emb[i] = sum / Float(max(end - start, 1))
        }
        // L2 normalize
        let norm = sqrt(emb.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<emb.count { emb[i] /= norm }
        }
        return emb
    }
}

public final class SpeakerGallery: @unchecked Sendable {
    private let store: KnowledgeStore
    private let matchThreshold: Float
    private var cache: [SpeakerProfile]

    public init(store: KnowledgeStore, matchThreshold: Float = PipelineConfig.default.speakerMatchThreshold) throws {
        self.store = store
        self.matchThreshold = matchThreshold
        self.cache = try store.allSpeakers()
    }

    public func reload() throws {
        cache = try store.allSpeakers()
    }

    public func matchOrCreate(embedding: [Float], provisionalIndex: Int) throws -> SpeakerProfile {
        var best: (SpeakerProfile, Float)?
        for speaker in cache {
            let score = EmbeddingMath.cosine(speaker.embedding, embedding)
            if score >= matchThreshold {
                if best == nil || score > best!.1 {
                    best = (speaker, score)
                }
            }
        }
        if var known = best?.0 {
            known.embedding = EmbeddingMath.ema(known.embedding, embedding)
            known.updatedAt = Date()
            try store.upsertSpeaker(known)
            if let idx = cache.firstIndex(where: { $0.id == known.id }) {
                cache[idx] = known
            }
            return known
        }

        let profile = SpeakerProfile(
            displayName: "Speaker \(provisionalIndex)",
            embedding: embedding
        )
        try store.upsertSpeaker(profile)
        cache.append(profile)
        return profile
    }

    public func rename(id: UUID, to name: String) throws {
        try store.renameSpeaker(id: id, to: name)
        try reload()
    }
}

public final class DiarizationService: @unchecked Sendable {
    private let embedder: PseudoECAPA
    private let gallery: SpeakerGallery

    public init(gallery: SpeakerGallery, embedder: PseudoECAPA = PseudoECAPA()) {
        self.gallery = gallery
        self.embedder = embedder
    }

    /// Assign speakers to transcript windows using embeddings from aligned PCM slices.
    public func diarize(
        pcm: [Float],
        sampleRate: Double,
        transcripts: [(startMs: Int, endMs: Int, text: String)]
    ) throws -> [DiarizedUtterance] {
        var results: [DiarizedUtterance] = []
        var nextIndex = 1
        var clusterCentroids: [[Float]] = []

        for t in transcripts {
            let start = max(Int(Double(t.startMs) / 1000.0 * sampleRate), 0)
            let end = min(Int(Double(t.endMs) / 1000.0 * sampleRate), pcm.count)
            let slice = start < end ? Array(pcm[start..<end]) : []
            let emb = embedder.embed(pcm: slice)

            var clusterID = clusterCentroids.count
            var bestScore: Float = -1
            for (idx, centroid) in clusterCentroids.enumerated() {
                let score = EmbeddingMath.cosine(centroid, emb)
                if score > bestScore {
                    bestScore = score
                    if score >= 0.78 { clusterID = idx }
                }
            }
            if clusterID == clusterCentroids.count {
                clusterCentroids.append(emb)
            } else {
                clusterCentroids[clusterID] = EmbeddingMath.ema(clusterCentroids[clusterID], emb, alpha: 0.3)
            }

            let profile = try gallery.matchOrCreate(embedding: emb, provisionalIndex: nextIndex)
            if profile.displayName.hasPrefix("Speaker ") {
                nextIndex = max(nextIndex, (Int(profile.displayName.split(separator: " ").last ?? "1") ?? 1) + 1)
            }

            results.append(
                DiarizedUtterance(
                    startMs: t.startMs,
                    endMs: t.endMs,
                    text: t.text,
                    speakerLabel: profile.displayName,
                    speakerID: profile.id,
                    embedding: emb
                )
            )
        }
        return results
    }
}
