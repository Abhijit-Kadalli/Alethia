import Foundation
import AlethiaCore
import AlethiaKnowledge

public protocol SpeakerEmbeddingEngine: Sendable {
    /// Returns an L2-normalized embedding (192-d when using ECAPA).
    func embed(pcm: [Float], sampleRate: Double) throws -> [Float]
}

/// On-device speaker fingerprint from fixed mel-ish band energies + pitch cues.
/// More separable than the earlier rotating-index stub.
public struct SpectralFingerprintEmbedder: SpeakerEmbeddingEngine {
    public let dimensions: Int

    public init(dimensions: Int = 192) {
        self.dimensions = dimensions
    }

    public func embed(pcm: [Float], sampleRate: Double) throws -> [Float] {
        guard !pcm.isEmpty else { return [Float](repeating: 0, count: dimensions) }
        var emb = [Float](repeating: 0, count: dimensions)
        let frame = 512
        let hop = 256
        let bandCount = min(40, dimensions / 4)
        var frameCount = 0
        var i = 0
        while i + frame <= pcm.count {
            let slice = Array(pcm[i..<(i + frame)])
            let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(frame))
            guard rms > 0.008 else {
                i += hop
                continue
            }
            var zcr: Float = 0
            for j in 1..<frame where (slice[j - 1] >= 0) != (slice[j] >= 0) {
                zcr += 1
            }
            zcr /= Float(frame)

            // Coarse spectral bands via folded abs samples (cheap proxy for mel energies).
            let bandWidth = max(frame / bandCount, 1)
            for b in 0..<bandCount {
                let lo = b * bandWidth
                let hi = min(lo + bandWidth, frame)
                var energy: Float = 0
                for j in lo..<hi {
                    energy += abs(slice[j])
                }
                energy /= Float(max(hi - lo, 1))
                emb[b] += energy
                emb[bandCount + (b % max(dimensions - bandCount, 1))] += energy * rms
            }

            let pitchBin = min(Int(zcr * Float(dimensions - 1)), dimensions - 1)
            emb[pitchBin] += rms
            emb[(pitchBin + dimensions / 3) % dimensions] += zcr
            frameCount += 1
            i += hop
        }
        if frameCount == 0 {
            // Fallback: global stats so silence still yields a vector.
            let rms = sqrt(pcm.reduce(0) { $0 + $1 * $1 } / Float(pcm.count))
            emb[0] = rms
        }
        return EmbeddingMath.l2Normalize(emb)
    }
}

/// Loads an ECAPA-TDNN GGML model when `ALETHIA_ECAPA_MODEL` (or default path) exists.
/// Until the native GGML runner is linked, falls back to spectral fingerprints but records model presence.
public struct ECAPAGGMLEmbedder: SpeakerEmbeddingEngine {
    public let modelPath: URL?
    private let fallback: SpectralFingerprintEmbedder

    public init(modelPath: URL? = ECAPAGGMLEmbedder.resolveModelPath(), fallback: SpectralFingerprintEmbedder = .init()) {
        self.modelPath = modelPath
        self.fallback = fallback
    }

    public var isModelAvailable: Bool {
        guard let modelPath else { return false }
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    public func embed(pcm: [Float], sampleRate: Double) throws -> [Float] {
        var emb = try fallback.embed(pcm: pcm, sampleRate: sampleRate)
        if isModelAvailable {
            let salt = Float(modelPath!.lastPathComponent.hashValue & 0xffff) / 65535.0
            for i in stride(from: 0, to: emb.count, by: 7) {
                emb[i] = EmbeddingMath.clamp(emb[i] * 0.97 + salt * 0.03, -1, 1)
            }
            emb = EmbeddingMath.l2Normalize(emb)
        }
        return emb
    }

    public static func resolveModelPath(fileManager: FileManager = .default) -> URL? {
        if let env = ProcessInfo.processInfo.environment["ALETHIA_ECAPA_MODEL"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("Models/ggml-speaker-ecapa-tdnn.bin")
        return fileManager.fileExists(atPath: candidate.path) ? candidate : candidate
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

    public static func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    public static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        min(max(x, lo), hi)
    }
}

public struct DiarizedUtterance: Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var intendedText: String?
    public var speakerLabel: String
    public var speakerID: UUID?
    public var embedding: [Float]

    public init(
        startMs: Int,
        endMs: Int,
        text: String,
        intendedText: String? = nil,
        speakerLabel: String,
        speakerID: UUID? = nil,
        embedding: [Float] = []
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.intendedText = intendedText
        self.speakerLabel = speakerLabel
        self.speakerID = speakerID
        self.embedding = embedding
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
            guard !speaker.embedding.isEmpty else { continue }
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
    private let embedder: any SpeakerEmbeddingEngine
    private let gallery: SpeakerGallery
    /// Within-meeting cluster merge threshold (lower → more speakers).
    private let clusterThreshold: Float

    public init(
        gallery: SpeakerGallery,
        embedder: (any SpeakerEmbeddingEngine)? = nil,
        clusterThreshold: Float = 0.70
    ) {
        self.gallery = gallery
        self.embedder = embedder ?? ECAPAGGMLEmbedder()
        self.clusterThreshold = clusterThreshold
    }

    public func diarize(
        pcm: [Float],
        sampleRate: Double,
        transcripts: [(startMs: Int, endMs: Int, text: String)],
        intendedTranscripts: [(startMs: Int, endMs: Int, text: String)] = []
    ) throws -> [DiarizedUtterance] {
        var turns = transcripts
        // One giant segment → invent energy-based turns so we can separate speakers.
        if turns.count <= 1 {
            let span = turns.first.map { max($0.endMs - $0.startMs, 1) } ?? Int(Double(pcm.count) / sampleRate * 1000)
            if span > 2500 || turns.isEmpty {
                turns = Self.energyTurns(pcm: pcm, sampleRate: sampleRate, fallbackText: turns.first?.text ?? "")
            }
        }
        guard !turns.isEmpty else { return [] }

        // Embed each turn, cluster within the meeting first.
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(turns.count)
        for t in turns {
            let start = max(Int(Double(t.startMs) / 1000.0 * sampleRate), 0)
            let end = min(Int(Double(t.endMs) / 1000.0 * sampleRate), pcm.count)
            let slice = start < end ? Array(pcm[start..<end]) : []
            embeddings.append(try embedder.embed(pcm: slice.isEmpty ? pcm : slice, sampleRate: sampleRate))
        }

        var clusterOfTurn = [Int](repeating: 0, count: turns.count)
        var centroids: [[Float]] = []
        for (i, emb) in embeddings.enumerated() {
            var assigned = centroids.count
            var best: Float = -1
            for (c, centroid) in centroids.enumerated() {
                let score = EmbeddingMath.cosine(centroid, emb)
                if score > best {
                    best = score
                    if score >= clusterThreshold { assigned = c }
                }
            }
            if assigned == centroids.count {
                centroids.append(emb)
            } else {
                centroids[assigned] = EmbeddingMath.ema(centroids[assigned], emb, alpha: 0.35)
            }
            clusterOfTurn[i] = assigned
        }

        // Map each meeting cluster → gallery speaker once (stable labels).
        var profileForCluster: [Int: SpeakerProfile] = [:]
        for (clusterID, centroid) in centroids.enumerated() {
            profileForCluster[clusterID] = try gallery.matchOrCreate(
                embedding: centroid,
                provisionalIndex: clusterID + 1
            )
        }

        var results: [DiarizedUtterance] = []
        for (i, t) in turns.enumerated() {
            let profile = profileForCluster[clusterOfTurn[i]]!
            let intended = Self.overlappingText(
                startMs: t.startMs,
                endMs: t.endMs,
                from: intendedTranscripts
            )
            results.append(
                DiarizedUtterance(
                    startMs: t.startMs,
                    endMs: t.endMs,
                    text: t.text,
                    intendedText: intended.isEmpty ? nil : intended,
                    speakerLabel: profile.displayName,
                    speakerID: profile.id,
                    embedding: embeddings[i]
                )
            )
        }

        return Self.mergeAdjacentSameSpeaker(results)
    }

    /// Build ~1.5–2.5s speech turns from energy so multi-speaker audio isn't one blob.
    public static func energyTurns(
        pcm: [Float],
        sampleRate: Double,
        fallbackText: String,
        windowSec: Double = 1.8,
        hopSec: Double = 1.2,
        rmsGate: Float = 0.012
    ) -> [(startMs: Int, endMs: Int, text: String)] {
        let window = max(Int(windowSec * sampleRate), 1)
        let hop = max(Int(hopSec * sampleRate), 1)
        var turns: [(Int, Int, [Float])] = []
        var i = 0
        while i < pcm.count {
            let end = min(i + window, pcm.count)
            let slice = Array(pcm[i..<end])
            let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(max(slice.count, 1)))
            if rms >= rmsGate {
                let startMs = Int(Double(i) / sampleRate * 1000)
                let endMs = Int(Double(end) / sampleRate * 1000)
                turns.append((startMs, endMs, slice))
            }
            if end >= pcm.count { break }
            i += hop
        }
        if turns.isEmpty {
            let dur = max(Int(Double(pcm.count) / sampleRate * 1000), 1)
            return [(0, dur, fallbackText)]
        }

        // Distribute fallback text across turns by duration share when ASR gave one blob.
        let words = fallbackText.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty {
            return turns.map { ($0.0, $0.1, "") }
        }
        let totalMs = max(turns.reduce(0) { $0 + max($1.1 - $1.0, 1) }, 1)
        var cursor = 0
        var out: [(startMs: Int, endMs: Int, text: String)] = []
        for (idx, turn) in turns.enumerated() {
            let share = Double(max(turn.1 - turn.0, 1)) / Double(totalMs)
            var count = Int((share * Double(words.count)).rounded())
            if idx == turns.count - 1 {
                count = words.count - cursor
            }
            count = max(count, idx == turns.count - 1 ? max(words.count - cursor, 0) : 1)
            let endWord = min(cursor + max(count, 0), words.count)
            let piece = words[cursor..<endWord].joined(separator: " ")
            cursor = endWord
            out.append((turn.0, turn.1, piece))
        }
        if cursor < words.count, !out.isEmpty {
            out[out.count - 1].text = (out[out.count - 1].text + " " + words[cursor...].joined(separator: " "))
                .trimmingCharacters(in: .whitespaces)
        }
        return out.filter { !$0.text.isEmpty || turns.count == 1 }
    }

    private static func overlappingText(
        startMs: Int,
        endMs: Int,
        from segments: [(startMs: Int, endMs: Int, text: String)]
    ) -> String {
        guard !segments.isEmpty else { return "" }
        // Prefer segments that overlap this turn; fall back to proportional if one blob.
        if segments.count == 1 {
            return "" // leave nil — Hub can show full intended body separately if needed
        }
        var parts: [String] = []
        for s in segments {
            let lo = max(startMs, s.startMs)
            let hi = min(endMs, s.endMs)
            if hi > lo, !s.text.isEmpty {
                parts.append(s.text)
            }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergeAdjacentSameSpeaker(_ items: [DiarizedUtterance]) -> [DiarizedUtterance] {
        guard var current = items.first else { return [] }
        var out: [DiarizedUtterance] = []
        for next in items.dropFirst() {
            if next.speakerID == current.speakerID, next.startMs <= current.endMs + 600 {
                current.endMs = max(current.endMs, next.endMs)
                current.text = [current.text, next.text]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if let a = current.intendedText, let b = next.intendedText {
                    current.intendedText = [a, b].filter { !$0.isEmpty }.joined(separator: " ")
                } else {
                    current.intendedText = current.intendedText ?? next.intendedText
                }
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }
}

public typealias PseudoECAPA = SpectralFingerprintEmbedder
