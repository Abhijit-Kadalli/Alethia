#if os(macOS)
import AVFoundation
import CoreML
import FluidAudio
import Foundation
import AlethiaCore

/// FluidAudio-backed speech engine: Parakeet TDT (ASR), Silero (VAD), pyannote (diarization).
///
/// Two `AsrManager`s share one set of loaded models so a meeting being finalized never
/// delays a dictation.
public actor SpeechEngine: SpeechEngineProtocol {
    public private(set) var variant: SpeechModelVariant
    /// BCP-47 hint for the multilingual model, or nil for auto.
    public private(set) var languageHint: String?

    private var models: AsrModels?
    private var realtime: AsrManager?
    private var batch: AsrManager?
    private var vad: VadManager?
    private var diarizerModels: DiarizerModels?
    /// Only one incremental session may use `realtime` at a time.
    private var liveSession: IncrementalTranscriber?
    private let log = Log("Speech")

    public init(variant: SpeechModelVariant, languageHint: String? = nil) {
        self.variant = variant
        self.languageHint = languageHint
    }

    public var isReady: Bool { realtime != nil }

    /// Switch model/language. Unloads the current recognizer when the model changes.
    /// Returns false if a live session is still accepting audio so the caller can retry.
    @discardableResult
    public func configure(variant: SpeechModelVariant, languageHint: String?) async -> Bool {
        if let liveSession, liveSession.isAccepting {
            return false
        }
        if let liveSession {
            await liveSession.waitUntilEnded()
            if liveSession.isAccepting { return false }
        }
        if variant != self.variant {
            await unload()
        }
        self.variant = variant
        self.languageHint = languageHint
        return true
    }

    var asrVersion: AsrModelVersion {
        variant == .parakeetV2English ? .v2 : .v3
    }

    // MARK: Lifecycle

    public func prepare() async throws {
        if realtime == nil {
            let version = asrVersion
            let directory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: directory, version: version) else {
                throw AlethiaError.modelsNotReady("The speech model has not been downloaded yet.")
            }
            let started = Date()
            let loaded: AsrModels
            do {
                loaded = try await AsrModels.load(from: directory, version: version)
            } catch {
                throw AlethiaError.modelsNotReady("Could not load the speech model: \(error.localizedDescription)")
            }
            // Mel chunk context misbehaves with the multilingual model on long audio (FluidAudio #594).
            let config = ASRConfig(melChunkContext: version != .v3)
            let realtime = AsrManager(config: config, models: loaded)
            let batch = AsrManager(config: config, models: loaded)
            self.models = loaded
            self.realtime = realtime
            self.batch = batch
            log.info("ASR \(version) loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        if vad == nil {
            do {
                vad = try await VadManager(config: VadConfig(defaultThreshold: 0.6))
            } catch {
                log.warning("VAD unavailable, using energy detector: \(error.localizedDescription)")
            }
        }
        if diarizerModels == nil {
            do {
                diarizerModels = try await DiarizerModels.load()
            } catch {
                log.warning("diarizer unavailable: \(error.localizedDescription)")
            }
        }
    }

    public func unload() async {
        liveSession?.cancel()
        await liveSession?.waitUntilEnded()
        liveSession = nil
        if let realtime { await realtime.cleanup() }
        if let batch { await batch.cleanup() }
        realtime = nil
        batch = nil
        models = nil
        vad = nil
        diarizerModels = nil
    }

    // MARK: ASR

    public func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        guard let realtime else { throw AlethiaError.modelsNotReady("Speech model is not loaded.") }
        return try await Self.run(realtime, samples: samples, language: fluidLanguage)
    }

    public func transcribeFile(_ url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> TranscriptSegment {
        guard let batch else { throw AlethiaError.modelsNotReady("Speech model is not loaded.") }
        let progressTask: Task<Void, Never>?
        if let progress {
            let stream = await batch.transcriptionProgressStream
            progressTask = Task {
                do {
                    for try await value in stream {
                        progress(value)
                    }
                } catch {}
            }
        } else {
            progressTask = nil
        }
        defer { progressTask?.cancel() }
        var state = TdtDecoderState.make(decoderLayers: await batch.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await batch.transcribeDiskBacked(url, decoderState: &state, language: fluidLanguage)
        } catch {
            throw AlethiaError.recognitionFailed(error.localizedDescription)
        }
        progress?(1)
        return Self.segment(from: result)
    }

    private static func run(_ manager: AsrManager, samples: [Float], language: Language?) async throws -> TranscriptSegment {
        // The model needs at least 300 ms; pad short clips with silence.
        var audio = samples
        let minimum = 16_000 * 3 / 10
        if audio.count < minimum {
            audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count))
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await manager.transcribe(audio, decoderState: &state, language: language)
        } catch {
            throw AlethiaError.recognitionFailed(error.localizedDescription)
        }
        var segment = segment(from: result)
        let durationMs = samples.count * 1000 / 16_000
        segment.endMs = min(segment.endMs, max(durationMs, segment.startMs))
        return segment
    }

    static func segment(from result: ASRResult) -> TranscriptSegment {
        let words = buildWordTimings(from: result.tokenTimings ?? []).map { w in
            TimedWord(text: w.word, startMs: Int(w.startTime * 1000), endMs: Int(w.endTime * 1000))
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let startMs = words.first?.startMs ?? 0
        let endMs = words.last?.endMs ?? Int(result.duration * 1000)
        return TranscriptSegment(startMs: startMs, endMs: endMs, text: text, words: words, confidence: result.confidence)
    }

    private var fluidLanguage: Language? {
        guard asrVersion == .v3, let hint = languageHint, !hint.isEmpty else { return nil }
        let code = hint.split(separator: "-").first.map(String.init)?.lowercased() ?? hint
        return Language(rawValue: code)
    }

    // MARK: Live

    public func startLiveTranscription(retainFullAudio: Bool = true) async throws -> LiveTranscriber {
        guard let realtime else { throw AlethiaError.modelsNotReady("Speech model is not loaded.") }
        if let liveSession {
            // Still feeding audio: a second caller (dictation + meeting) is a real conflict.
            if liveSession.isAccepting {
                throw AlethiaError.invalidInput("Speech recognition is already in use. Stop dictation or the meeting first.")
            }
            // Cancel/finish already started — wait out the in-flight decode, then reuse.
            await liveSession.waitUntilEnded()
        }
        let session = IncrementalTranscriber(manager: realtime, language: fluidLanguage, retainFullAudio: retainFullAudio)
        liveSession = session
        return session
    }

    // MARK: VAD

    public func speechRanges(_ samples: [Float]) async throws -> [ClosedRange<Int>] {
        guard let vad else { return EnergyVAD.speechRanges(samples) }
        do {
            let segments = try await vad.segmentSpeech(samples, config: VadSegmentationConfig(minSilenceDuration: 0.5, maxSpeechDuration: 60))
            return segments.map { Int($0.startTime * 1000)...Int($0.endTime * 1000) }
        } catch {
            log.warning("VAD failed, using energy detector: \(error.localizedDescription)")
            return EnergyVAD.speechRanges(samples)
        }
    }

    // MARK: Diarization

    public func diarize(_ samples: [Float], progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerSegment] {
        guard let diarizerModels else {
            throw AlethiaError.diarizationFailed("Speaker model is not available.")
        }
        // The diarizer is synchronous and CPU heavy; keep it off this actor's executor.
        let task = Task.detached(priority: .userInitiated) { () throws -> [SpeakerSegment] in
            let manager = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.7, minSpeechDuration: 0.6, minSilenceGap: 0.4))
            manager.initialize(models: diarizerModels)
            defer { manager.cleanup() }
            let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000, progressHandler: { value in
                progress?(value)
            })
            return result.segments.map { seg in
                SpeakerSegment(
                    clusterID: seg.speakerId,
                    startMs: Int(seg.startTimeSeconds * 1000),
                    endMs: Int(seg.endTimeSeconds * 1000),
                    embedding: seg.embedding.isEmpty ? nil : seg.embedding
                )
            }
        }
        do {
            return try await task.value
        } catch {
            throw AlethiaError.diarizationFailed(error.localizedDescription)
        }
    }
}

/// Live partials by re-decoding the open (uncommitted) audio every few hundred milliseconds
/// with the batch model. Segments are committed at pauses so each decode stays short and the
/// text before a pause stops changing. Punctuation and casing come for free from Parakeet.
final class IncrementalTranscriber: LiveTranscriber, @unchecked Sendable {
    let updates: AsyncStream<LiveTranscriptUpdate>

    private let manager: AsrManager
    private let language: Language?
    private let continuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    private let lock = NSLock()
    private var all: [Float] = []
    private var committedSamples = 0
    private var committed: [TranscriptSegment] = []
    private var decodedUpTo = 0
    /// Samples discarded from the front of `all` after a commit (when not retaining full audio).
    private var originSamples = 0
    private let retainFullAudio: Bool
    private var finished = false
    private var ended = false
    private var awaitingFinal = false
    private var endedWaiters: [CheckedContinuation<Void, Never>] = []
    private var loop: Task<Void, Never>?

    private let sampleRate = 16_000
    private let tickMs = 450
    private let minDecodeSamples = 16_000 * 6 / 10
    private let commitAfterSamples = 16_000 * 8
    private let hardCommitSamples = 16_000 * 20

    init(manager: AsrManager, language: Language?, retainFullAudio: Bool = true) {
        self.manager = manager
        self.language = language
        self.retainFullAudio = retainFullAudio
        var cont: AsyncStream<LiveTranscriptUpdate>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// True until `cancel()` / `finish()` has been requested. A winding-down session is not accepting.
    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    /// True until `cancel()` / `finish()` has completed in-flight recognition.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !ended
    }

    /// Suspends until the decode loop (and `finish()`'s final pass) have released the ASR manager.
    func waitUntilEnded() async {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            endedWaiters.append(continuation)
            lock.unlock()
        }
    }

    func feed(_ samples: [Float]) {
        lock.lock()
        if !finished {
            all.append(contentsOf: samples)
        }
        lock.unlock()
    }

    func finish() async throws -> TranscriptSegment {
        lock.lock()
        finished = true
        awaitingFinal = true
        let audio = all
        lock.unlock()
        loop?.cancel()
        if let loop { await loop.value }
        continuation.finish()
        defer { markEnded() }
        guard !audio.isEmpty else {
            return TranscriptSegment(startMs: 0, endMs: 0, text: "")
        }
        return try await SpeechEngine.transcribeSamples(audio, with: manager, language: language)
    }

    func cancel() {
        lock.lock()
        finished = true
        lock.unlock()
        loop?.cancel()
        continuation.finish()
        // `ended` flips when `runLoop` returns so an overlapping decode still occupies the manager.
    }

    private func markEnded() {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        let waiters = endedWaiters
        endedWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func runLoop() async {
        defer {
            lock.lock()
            let keepForFinal = awaitingFinal
            lock.unlock()
            if !keepForFinal { markEnded() }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(tickMs))
            if Task.isCancelled { return }

            lock.lock()
            if finished { lock.unlock(); return }
            let openStart = committedSamples
            let open = Array(all[openStart...])
            let hasNewAudio = all.count > decodedUpTo
            lock.unlock()

            guard hasNewAudio, open.count >= minDecodeSamples else { continue }

            // Commit at a pause once the open region is long enough (or unconditionally when very long).
            var commitBoundary: Int?
            if open.count >= hardCommitSamples {
                commitBoundary = EnergyVAD.lastSilenceStart(in: open, minSilenceMs: 300) ?? open.count
            } else if open.count >= commitAfterSamples, let silence = EnergyVAD.lastSilenceStart(in: open, minSilenceMs: 500) {
                commitBoundary = silence
            }

            if let boundary = commitBoundary, boundary >= minDecodeSamples {
                let piece = Array(open[..<boundary])
                if let segment = try? await SpeechEngine.transcribeSamples(piece, with: manager, language: language),
                   !segment.text.isEmpty {
                    let offsetMs = (originSamples + openStart) * 1000 / sampleRate
                    var shifted = segment
                    shifted.startMs += offsetMs
                    shifted.endMs += offsetMs
                    shifted.words = segment.words.map {
                        TimedWord(text: $0.text, startMs: $0.startMs + offsetMs, endMs: $0.endMs + offsetMs, confidence: $0.confidence)
                    }
                    lock.lock()
                    committed.append(shifted)
                    committedSamples = openStart + boundary
                    if !retainFullAudio, committedSamples > 0, committedSamples <= all.count {
                        all.removeFirst(committedSamples)
                        originSamples += committedSamples
                        decodedUpTo = max(0, decodedUpTo - committedSamples)
                        committedSamples = 0
                    }
                    lock.unlock()
                }
                // Failed/empty decode leaves the window uncommitted so finish() can retry it.
                continue
            }

            lock.lock()
            decodedUpTo = all.count
            lock.unlock()
            let segment = try? await SpeechEngine.transcribeSamples(open, with: manager, language: language)
            lock.lock()
            let snapshot = LiveTranscriptUpdate(
                committed: committed,
                volatile: segment?.text ?? "",
                volatileStartMs: (originSamples + openStart) * 1000 / sampleRate
            )
            let stillRunning = !finished
            lock.unlock()
            if stillRunning {
                continuation.yield(snapshot)
            }
        }
    }
}

extension SpeechEngine {
    static func transcribeSamples(_ samples: [Float], with manager: AsrManager, language: Language?) async throws -> TranscriptSegment {
        try await run(manager, samples: samples, language: language)
    }
}
#endif
