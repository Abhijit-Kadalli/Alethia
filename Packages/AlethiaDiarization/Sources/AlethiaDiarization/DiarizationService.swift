import Foundation
import Accelerate
import AlethiaCore
import AlethiaKnowledge

public protocol SpeakerEmbeddingEngine: Sendable {
    /// Returns an L2-normalized embedding (192-d when using ECAPA).
    func embed(pcm: [Float], sampleRate: Double) throws -> [Float]
}

/// On-device speaker fingerprint: log-band energies, pitch, and spectral shape.
/// Used only when the SpeechBrain ECAPA sidecar is unavailable.
public struct SpectralFingerprintEmbedder: SpeakerEmbeddingEngine {
    public let dimensions: Int

    public init(dimensions: Int = 192) {
        self.dimensions = dimensions
    }

    public func embed(pcm: [Float], sampleRate: Double) throws -> [Float] {
        guard !pcm.isEmpty else { return [Float](repeating: 0, count: dimensions) }

        let frame = 512
        let hop = 320 // 20ms @ 16k — enough resolution, far cheaper than 10ms
        let bandCount = 32
        var bandSum = [Float](repeating: 0, count: bandCount)
        var bandSumSq = [Float](repeating: 0, count: bandCount)
        var pitchHist = [Float](repeating: 0, count: 48)
        var peakHist = [Float](repeating: 0, count: 48)
        var centroidSum: Float = 0
        var rolloffSum: Float = 0
        var flatnessSum: Float = 0
        var zcrSum: Float = 0
        var f0Sum: Float = 0
        var f0Count: Float = 0
        var frameCount = 0

        // Adaptive speech gate from global RMS.
        let globalRMS = sqrt(pcm.reduce(0) { $0 + $1 * $1 } / Float(pcm.count))
        let gate = max(globalRMS * 0.35, 0.006)

        // Reusable FFT setup (radix-2, 512).
        let log2n = vDSP_Length(9) // 2^9 = 512
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return EmbeddingMath.l2Normalize([globalRMS] + [Float](repeating: 0, count: dimensions - 1))
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        var windowed = [Float](repeating: 0, count: frame)
        var realp = [Float](repeating: 0, count: frame / 2)
        var imagp = [Float](repeating: 0, count: frame / 2)
        var mags = [Float](repeating: 0, count: frame / 2)

        var i = 0
        var prevBands: [Float]?
        var deltaSum = [Float](repeating: 0, count: bandCount)
        while i + frame <= pcm.count {
            var energy: Float = 0
            for j in 0..<frame {
                let w = 0.5 - 0.5 * cos(2 * Float.pi * Float(j) / Float(frame - 1)) // Hann
                let s = pcm[i + j] * w
                windowed[j] = s
                energy += s * s
            }
            let rms = sqrt(energy / Float(frame))
            guard rms >= gate else {
                i += hop
                continue
            }

            Self.fftMagnitudes(
                setup: fftSetup,
                log2n: log2n,
                windowed: &windowed,
                realp: &realp,
                imagp: &imagp,
                mags: &mags
            )
            let bands = Self.logMelBands(mags: mags, bandCount: bandCount, sampleRate: sampleRate)
            for b in 0..<bandCount {
                bandSum[b] += bands[b]
                bandSumSq[b] += bands[b] * bands[b]
            }
            if let prev = prevBands {
                for b in 0..<bandCount {
                    deltaSum[b] += abs(bands[b] - prev[b])
                }
            }
            prevBands = bands

            let (centroid, rolloff, flatness) = Self.spectralShape(mags: mags, sampleRate: sampleRate)
            centroidSum += centroid
            rolloffSum += rolloff
            flatnessSum += flatness

            // Spectral peak bin (discriminative for tonal / voiced speech).
            if let peakIdx = mags.indices.max(by: { mags[$0] < mags[$1] }) {
                let peakHz = Float(peakIdx) / Float(max(mags.count - 1, 1)) * Float(sampleRate / 2)
                let pnorm = min(max((peakHz - 80) / 720, 0), 0.999) // 80–800 Hz
                peakHist[Int(pnorm * Float(peakHist.count))] += 1
            }

            var zcr: Float = 0
            for j in 1..<frame where (windowed[j - 1] >= 0) != (windowed[j] >= 0) {
                zcr += 1
            }
            zcr /= Float(frame)
            zcrSum += zcr

            if let hz = Self.estimatePitchHz(windowed, sampleRate: sampleRate) {
                let norm = min(max((hz - 70) / 250, 0), 0.999)
                let bin = Int(norm * Float(pitchHist.count))
                pitchHist[bin] += 1
                f0Sum += hz
                f0Count += 1
            }

            frameCount += 1
            i += hop
        }

        var emb = [Float](repeating: 0, count: dimensions)
        guard frameCount > 0 else {
            emb[0] = globalRMS
            return EmbeddingMath.l2Normalize(emb)
        }
        let n = Float(frameCount)
        let means = bandSum.map { $0 / n }
        let stds = (0..<bandCount).map { b -> Float in
            let mean = means[b]
            return sqrt(max(bandSumSq[b] / n - mean * mean, 0))
        }
        let deltas = deltaSum.map { $0 / n }
        let pitch = pitchHist.map { $0 / n }
        let peaks = peakHist.map { $0 / n }
        let f0 = f0Count > 0 ? (f0Sum / f0Count) / 400.0 : 0 // ~0–1

        // Mel bands: z-score so absolute level doesn't dominate.
        let melN = EmbeddingMath.l2Normalize(EmbeddingMath.zscore(means + stds + deltas))
        // Pitch / peak histograms — equal L2 energy so cosine isn't drowned by mel bins.
        let identity = pitch + peaks + [
            centroidSum / n,
            rolloffSum / n,
            flatnessSum / n,
            zcrSum / n,
            f0, f0, f0, f0
        ]
        let idN = EmbeddingMath.l2Normalize(identity)

        var mixed = melN + idN
        if mixed.count < dimensions {
            mixed += [Float](repeating: 0, count: dimensions - mixed.count)
        } else if mixed.count > dimensions {
            mixed = Array(mixed.prefix(dimensions))
        }
        return EmbeddingMath.l2Normalize(mixed)
    }

    /// Real DFT magnitudes via Accelerate FFT.
    private static func fftMagnitudes(
        setup: FFTSetup,
        log2n: vDSP_Length,
        windowed: inout [Float],
        realp: inout [Float],
        imagp: inout [Float],
        mags: inout [Float]
    ) {
        let n = windowed.count
        let half = n / 2
        realp.withUnsafeMutableBufferPointer { reBuf in
            imagp.withUnsafeMutableBufferPointer { imBuf in
                var split = DSPSplitComplex(realp: reBuf.baseAddress!, imagp: imBuf.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // Pack format: bin 0 holds DC/Nyquist specially; clamp tiny values.
        for i in 0..<half {
            mags[i] = sqrt(max(mags[i], 0))
        }
    }

    private static func logMelBands(mags: [Float], bandCount: Int, sampleRate: Double) -> [Float] {
        let nyquist = sampleRate / 2
        let melMax = Self.hzToMel(nyquist)
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let mel0 = melMax * Double(b) / Double(bandCount)
            let mel1 = melMax * Double(b + 1) / Double(bandCount)
            let f0 = Self.melToHz(mel0)
            let f1 = Self.melToHz(mel1)
            let i0 = max(Int(f0 / nyquist * Double(mags.count)), 0)
            let i1 = min(Int(f1 / nyquist * Double(mags.count)), mags.count)
            guard i1 > i0 else { continue }
            var e: Float = 0
            for i in i0..<i1 { e += mags[i] }
            e /= Float(i1 - i0)
            bands[b] = log(max(e, 1e-8))
        }
        return bands
    }

    private static func spectralShape(mags: [Float], sampleRate: Double) -> (Float, Float, Float) {
        let n = mags.count
        guard n > 1 else { return (0, 0, 0) }
        var total: Float = 0
        var weighted: Float = 0
        for i in 0..<n {
            let f = Float(i) / Float(n) * Float(sampleRate / 2)
            total += mags[i]
            weighted += mags[i] * f
        }
        guard total > 0 else { return (0, 0, 0) }
        let centroid = weighted / total
        let target = total * 0.85
        var cum: Float = 0
        var rolloff: Float = Float(sampleRate / 2)
        for i in 0..<n {
            cum += mags[i]
            if cum >= target {
                rolloff = Float(i) / Float(n) * Float(sampleRate / 2)
                break
            }
        }
        // Spectral flatness (geometric / arithmetic mean).
        var logSum: Float = 0
        for m in mags { logSum += log(max(m, 1e-12)) }
        let geo = exp(logSum / Float(n))
        let flatness = geo / (total / Float(n))
        return (centroid / Float(sampleRate / 2), rolloff / Float(sampleRate / 2), flatness)
    }

    private static func estimatePitchHz(_ frame: [Float], sampleRate: Double) -> Float? {
        let minLag = Int(sampleRate / 400) // 400 Hz
        let maxLag = min(Int(sampleRate / 70), frame.count / 2) // 70 Hz
        guard maxLag > minLag + 2 else { return nil }
        var bestLag = minLag
        var bestCorr: Float = -1
        let energy = frame.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-6 else { return nil }
        for lag in minLag...maxLag {
            var corr: Float = 0
            for i in 0..<(frame.count - lag) {
                corr += frame[i] * frame[i + lag]
            }
            corr /= energy
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }
        guard bestCorr > 0.25 else { return nil }
        return Float(sampleRate) / Float(bestLag)
    }

    private static func hzToMel(_ hz: Double) -> Double {
        2595 * log10(1 + hz / 700)
    }

    private static func melToHz(_ mel: Double) -> Double {
        700 * (pow(10, mel / 2595) - 1)
    }
}

/// Real ECAPA-TDNN via the local sidecar when available; spectral fingerprints otherwise.
public struct ECAPAGGMLEmbedder: SpeakerEmbeddingEngine {
    public let modelPath: URL?
    private let fallback: SpectralFingerprintEmbedder
    private let sidecar: ECAPASidecarEmbedder
    private let preferSidecar: Bool

    public init(
        modelPath: URL? = ECAPAGGMLEmbedder.resolveModelPath(),
        fallback: SpectralFingerprintEmbedder = .init(),
        sidecar: ECAPASidecarEmbedder = .fromEnvironment(),
        preferSidecar: Bool = true
    ) {
        self.modelPath = modelPath
        self.fallback = fallback
        self.sidecar = sidecar
        self.preferSidecar = preferSidecar
    }

    public var isModelAvailable: Bool {
        if preferSidecar, ECAPASidecarEmbedder.isAvailable(baseURL: sidecar.baseURL) {
            return true
        }
        guard let modelPath else { return false }
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    public var backendName: String {
        if preferSidecar, ECAPASidecarEmbedder.isAvailable(baseURL: sidecar.baseURL) {
            return "speechbrain-ecapa"
        }
        return "spectral-fallback"
    }

    public func embed(pcm: [Float], sampleRate: Double) throws -> [Float] {
        if preferSidecar {
            do {
                let emb = try sidecar.embed(pcm: pcm, sampleRate: sampleRate)
                if emb.contains(where: { abs($0) > 1e-8 }) {
                    return emb
                }
            } catch {
                // Fall through to spectral.
            }
        }
        // Native GGML runner not linked yet.
        return try fallback.embed(pcm: pcm, sampleRate: sampleRate)
    }

    public static func resolveModelPath(fileManager: FileManager = .default) -> URL? {
        if let env = ProcessInfo.processInfo.environment["ALETHIA_ECAPA_GGML"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Alethia/Models/ggml-speaker-ecapa-tdnn.bin")
        if let support, fileManager.fileExists(atPath: support.path) { return support }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Models/ggml-speaker-ecapa-tdnn.bin")
        return fileManager.fileExists(atPath: cwd.path) ? cwd : nil
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

    public static func zscore(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let mean = v.reduce(0, +) / Float(v.count)
        var varSum: Float = 0
        for x in v {
            let d = x - mean
            varSum += d * d
        }
        let std = sqrt(varSum / Float(v.count))
        guard std > 1e-8 else { return v.map { $0 - mean } }
        return v.map { ($0 - mean) / std }
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
    public var matchConfidence: Float?
    public var suggestedSpeakerLabel: String?

    public init(
        startMs: Int,
        endMs: Int,
        text: String,
        intendedText: String? = nil,
        speakerLabel: String,
        speakerID: UUID? = nil,
        embedding: [Float] = [],
        matchConfidence: Float? = nil,
        suggestedSpeakerLabel: String? = nil
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.intendedText = intendedText
        self.speakerLabel = speakerLabel
        self.speakerID = speakerID
        self.embedding = embedding
        self.matchConfidence = matchConfidence
        self.suggestedSpeakerLabel = suggestedSpeakerLabel
    }
}

public struct SpeakerMatchResult: Sendable {
    public let profile: SpeakerProfile
    public let score: Float
    public let meetingLabel: String
    public let suggestedLabel: String?
}

public final class SpeakerGallery: @unchecked Sendable {
    private let store: KnowledgeStore
    private let matchThreshold: Float
    private let suggestionThreshold: Float
    private var cache: [SpeakerProfile]

    public init(
        store: KnowledgeStore,
        matchThreshold: Float = PipelineConfig.default.speakerMatchThreshold,
        suggestionThreshold: Float = PipelineConfig.default.speakerSuggestionThreshold
    ) throws {
        self.store = store
        self.matchThreshold = matchThreshold
        self.suggestionThreshold = suggestionThreshold
        self.cache = try store.allSpeakers()
    }

    public func reload() throws {
        cache = try store.allSpeakers()
    }

    /// Best match among **user-labeled** gallery voices only (avoids Person-N pollution).
    public func bestLabeledMatch(embedding: [Float]) -> (SpeakerProfile, Float)? {
        var best: (SpeakerProfile, Float)?
        for speaker in cache where speaker.isUserLabeled && !speaker.embedding.isEmpty {
            let score = EmbeddingMath.cosine(speaker.embedding, embedding)
            if best == nil || score > best!.1 {
                best = (speaker, score)
            }
        }
        return best
    }

    /// Enrolls/updates a meeting cluster. Always returns a local `Person N` label;
    /// only suggests a gallery name when confidence ≥ suggestion threshold and the gallery entry is user-labeled.
    public func resolveCluster(embedding: [Float], personIndex: Int) throws -> SpeakerMatchResult {
        let meetingLabel = SpeakerProfile.provisionalLabel(index: personIndex)

        if let (known, score) = bestLabeledMatch(embedding: embedding), score >= matchThreshold {
            var profile = known
            // Only reinforce the centroid when the match is fairly strong.
            if score >= 0.70 {
                profile.embedding = EmbeddingMath.ema(known.embedding, embedding, alpha: 0.12)
                profile.updatedAt = Date()
                try store.upsertSpeaker(profile)
                if let idx = cache.firstIndex(where: { $0.id == profile.id }) {
                    cache[idx] = profile
                }
            }
            let suggestion: String? = (score >= suggestionThreshold) ? profile.displayName : nil
            return SpeakerMatchResult(
                profile: profile,
                score: score,
                meetingLabel: meetingLabel,
                suggestedLabel: suggestion
            )
        }

        // Meeting-local identity. Stored so the user can label it; excluded from matching until labeled.
        let profile = SpeakerProfile(
            displayName: meetingLabel,
            embedding: embedding
        )
        try store.upsertSpeaker(profile)
        cache.append(profile)
        return SpeakerMatchResult(
            profile: profile,
            score: 1,
            meetingLabel: meetingLabel,
            suggestedLabel: nil
        )
    }

    public func matchOrCreate(embedding: [Float], provisionalIndex: Int) throws -> SpeakerProfile {
        try resolveCluster(embedding: embedding, personIndex: provisionalIndex).profile
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
        clusterThreshold: Float = 0.45
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
        // Always segment from audio for speaker turns — ASR phrase boundaries ≠ speaker changes.
        let windows = Self.speechWindows(pcm: pcm, sampleRate: sampleRate)
        guard !windows.isEmpty else { return [] }

        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(windows.count)
        for w in windows {
            let start = max(Int(Double(w.startMs) / 1000.0 * sampleRate), 0)
            let end = min(Int(Double(w.endMs) / 1000.0 * sampleRate), pcm.count)
            let slice = start < end ? Array(pcm[start..<end]) : []
            embeddings.append(try embedder.embed(pcm: slice.isEmpty ? pcm : slice, sampleRate: sampleRate))
        }

        let clusterOfWindow = Self.clusterEmbeddings(embeddings, threshold: clusterThreshold)

        // Stable Person numbering by first appearance in time.
        var firstSeenCluster: [Int: Int] = [:]
        var personIndexOfCluster: [Int: Int] = [:]
        var nextPerson = 1
        for (i, c) in clusterOfWindow.enumerated() {
            if firstSeenCluster[c] == nil {
                firstSeenCluster[c] = i
                personIndexOfCluster[c] = nextPerson
                nextPerson += 1
            }
        }

        var resolveForCluster: [Int: SpeakerMatchResult] = [:]
        var centroidForCluster: [Int: [Float]] = [:]
        for (i, c) in clusterOfWindow.enumerated() {
            if let existing = centroidForCluster[c] {
                centroidForCluster[c] = EmbeddingMath.ema(existing, embeddings[i], alpha: 0.35)
            } else {
                centroidForCluster[c] = embeddings[i]
            }
        }
        for (clusterID, centroid) in centroidForCluster {
            let personIndex = personIndexOfCluster[clusterID] ?? (clusterID + 1)
            resolveForCluster[clusterID] = try gallery.resolveCluster(
                embedding: centroid,
                personIndex: personIndex
            )
        }

        var results: [DiarizedUtterance] = []
        for (i, w) in windows.enumerated() {
            let resolved = resolveForCluster[clusterOfWindow[i]]!
            let text = Self.overlappingText(startMs: w.startMs, endMs: w.endMs, from: transcripts)
            let intended = Self.overlappingText(startMs: w.startMs, endMs: w.endMs, from: intendedTranscripts)
            // Skip empty non-speech windows that somehow slipped through.
            if text.isEmpty && intended.isEmpty { continue }
            results.append(
                DiarizedUtterance(
                    startMs: w.startMs,
                    endMs: w.endMs,
                    text: text.isEmpty ? "…" : text,
                    intendedText: intended.isEmpty ? nil : intended,
                    speakerLabel: resolved.meetingLabel,
                    speakerID: resolved.profile.id,
                    embedding: embeddings[i],
                    matchConfidence: resolved.suggestedLabel == nil ? nil : resolved.score,
                    suggestedSpeakerLabel: resolved.suggestedLabel
                )
            )
        }

        // If overlap assignment wiped everything, fall back to proportional text on windows.
        if results.isEmpty {
            let blob = transcripts.map(\.text).joined(separator: " ")
            let words = blob.split(whereSeparator: \.isWhitespace).map(String.init)
            if !words.isEmpty, !windows.isEmpty {
                let totalMs = max(windows.reduce(0) { $0 + max($1.endMs - $1.startMs, 1) }, 1)
                var cursor = 0
                for (i, w) in windows.enumerated() {
                    let resolved = resolveForCluster[clusterOfWindow[i]]!
                    let share = Double(max(w.endMs - w.startMs, 1)) / Double(totalMs)
                    var count = Int((share * Double(words.count)).rounded())
                    if i == windows.count - 1 { count = words.count - cursor }
                    let end = min(cursor + max(count, 0), words.count)
                    let piece = words[cursor..<end].joined(separator: " ")
                    cursor = end
                    guard !piece.isEmpty else { continue }
                    results.append(
                        DiarizedUtterance(
                            startMs: w.startMs,
                            endMs: w.endMs,
                            text: piece,
                            speakerLabel: resolved.meetingLabel,
                            speakerID: resolved.profile.id,
                            embedding: embeddings[i],
                            matchConfidence: resolved.suggestedLabel == nil ? nil : resolved.score,
                            suggestedSpeakerLabel: resolved.suggestedLabel
                        )
                    )
                }
            }
        }

        return Self.mergeAdjacentSameSpeaker(results)
    }

    /// Speech regions from adaptive energy, split on pauses and capped for embedding quality.
    public static func speechWindows(
        pcm: [Float],
        sampleRate: Double,
        frameMs: Double = 30,
        minSpeechMs: Int = 450,
        maxWindowMs: Int = 2400,
        pauseMs: Int = 350
    ) -> [(startMs: Int, endMs: Int)] {
        guard !pcm.isEmpty else { return [] }
        let frame = max(Int(sampleRate * frameMs / 1000), 1)
        var rmsFrames: [Float] = []
        var i = 0
        while i < pcm.count {
            let end = min(i + frame, pcm.count)
            let slice = pcm[i..<end]
            let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(max(slice.count, 1)))
            rmsFrames.append(rms)
            i += frame
        }
        guard !rmsFrames.isEmpty else { return [] }

        // Noise floor ≈ 5th percentile (must stay below speech even when silence is rare).
        let sorted = rmsFrames.sorted()
        let noiseIdx = min(max(Int(Double(sorted.count) * 0.05), 0), sorted.count - 1)
        let noise = sorted[noiseIdx]
        let median = sorted[sorted.count / 2]
        let gate = max(max(noise * 3.5, median * 0.25), 0.006)

        let speech = rmsFrames.map { $0 >= gate }
        // Fill only very short dropouts (< ~180ms) so real speaker pauses stay splits.
        let gapFrames = max(Int(180.0 / frameMs), 1)
        var filled = speech
        var run = 0
        for idx in 0..<speech.count {
            if !speech[idx] {
                run += 1
            } else {
                if run > 0 && run <= gapFrames {
                    for j in (idx - run)..<idx { filled[j] = true }
                }
                run = 0
            }
        }

        var regions: [(Int, Int)] = []
        var start: Int?
        for (idx, on) in filled.enumerated() {
            if on, start == nil { start = idx }
            if !on, let s = start {
                regions.append((s, idx))
                start = nil
            }
        }
        if let s = start { regions.append((s, filled.count)) }

        var windows: [(startMs: Int, endMs: Int)] = []
        for (s, e) in regions {
            let startMs = Int(Double(s * frame) / sampleRate * 1000)
            let endMs = Int(Double(e * frame) / sampleRate * 1000)
            guard endMs - startMs >= minSpeechMs else { continue }
            // Split long regions so embeddings stay speaker-local.
            var cursor = startMs
            while cursor < endMs {
                let chunkEnd = min(cursor + maxWindowMs, endMs)
                if chunkEnd - cursor >= minSpeechMs {
                    windows.append((cursor, chunkEnd))
                }
                if chunkEnd >= endMs { break }
                cursor += maxWindowMs - 400 // slight overlap
            }
        }

        if windows.isEmpty {
            let dur = max(Int(Double(pcm.count) / sampleRate * 1000), 1)
            return [(0, dur)]
        }
        return windows
    }

    /// Greedy online clustering with cosine threshold.
    public static func clusterEmbeddings(_ embeddings: [[Float]], threshold: Float) -> [Int] {
        var clusterOf = [Int](repeating: 0, count: embeddings.count)
        var centroids: [[Float]] = []
        for (i, emb) in embeddings.enumerated() {
            var assigned = centroids.count
            var best: Float = -1
            for (c, centroid) in centroids.enumerated() {
                let score = EmbeddingMath.cosine(centroid, emb)
                if score > best {
                    best = score
                    if score >= threshold { assigned = c }
                }
            }
            if assigned == centroids.count {
                centroids.append(emb)
            } else {
                centroids[assigned] = EmbeddingMath.ema(centroids[assigned], emb, alpha: 0.30)
            }
            clusterOf[i] = assigned
        }
        return clusterOf
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
        let windows = speechWindows(pcm: pcm, sampleRate: sampleRate)
        let words = fallbackText.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty {
            return windows.map { ($0.startMs, $0.endMs, "") }
        }
        let totalMs = max(windows.reduce(0) { $0 + max($1.endMs - $1.startMs, 1) }, 1)
        var cursor = 0
        var out: [(startMs: Int, endMs: Int, text: String)] = []
        for (idx, turn) in windows.enumerated() {
            let share = Double(max(turn.endMs - turn.startMs, 1)) / Double(totalMs)
            var count = Int((share * Double(words.count)).rounded())
            if idx == windows.count - 1 {
                count = words.count - cursor
            }
            count = max(count, idx == windows.count - 1 ? max(words.count - cursor, 0) : 1)
            let endWord = min(cursor + max(count, 0), words.count)
            let piece = words[cursor..<endWord].joined(separator: " ")
            cursor = endWord
            out.append((turn.startMs, turn.endMs, piece))
        }
        if cursor < words.count, !out.isEmpty {
            out[out.count - 1].text = (out[out.count - 1].text + " " + words[cursor...].joined(separator: " "))
                .trimmingCharacters(in: .whitespaces)
        }
        return out.filter { !$0.text.isEmpty || windows.count == 1 }
    }

    private static func overlappingText(
        startMs: Int,
        endMs: Int,
        from segments: [(startMs: Int, endMs: Int, text: String)]
    ) -> String {
        guard !segments.isEmpty else { return "" }
        if segments.count == 1 {
            let only = segments[0]
            // Single ASR blob: take a proportional word slice for this window.
            let words = only.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return "" }
            let total = max(only.endMs - only.startMs, 1)
            let rel0 = Double(max(startMs - only.startMs, 0)) / Double(total)
            let rel1 = Double(min(endMs - only.startMs, total)) / Double(total)
            let i0 = min(max(Int(rel0 * Double(words.count)), 0), words.count)
            let i1 = min(max(Int(rel1 * Double(words.count)), i0), words.count)
            return words[i0..<i1].joined(separator: " ")
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
            if next.speakerID == current.speakerID, next.startMs <= current.endMs + 400 {
                current.endMs = max(current.endMs, next.endMs)
                current.text = [current.text, next.text]
                    .filter { !$0.isEmpty && $0 != "…" }
                    .joined(separator: " ")
                if let a = current.intendedText, let b = next.intendedText {
                    current.intendedText = [a, b].filter { !$0.isEmpty }.joined(separator: " ")
                } else {
                    current.intendedText = current.intendedText ?? next.intendedText
                }
                if let a = current.matchConfidence, let b = next.matchConfidence {
                    current.matchConfidence = max(a, b)
                } else {
                    current.matchConfidence = current.matchConfidence ?? next.matchConfidence
                }
                current.suggestedSpeakerLabel = current.suggestedSpeakerLabel ?? next.suggestedSpeakerLabel
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
