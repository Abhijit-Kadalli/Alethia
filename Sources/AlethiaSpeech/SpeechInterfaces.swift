import Foundation
import AlethiaCore

/// Partial result while audio is still arriving.
public struct LiveTranscriptUpdate: Sendable, Equatable {
    /// Segments that were closed at a pause and will not change. Timings are relative to the
    /// start of the session in milliseconds.
    public var committed: [TranscriptSegment]
    /// Text for the audio after the last committed segment; may still change.
    public var volatile: String
    /// Start of the volatile region, ms from session start.
    public var volatileStartMs: Int

    public init(committed: [TranscriptSegment] = [], volatile: String = "", volatileStartMs: Int = 0) {
        self.committed = committed
        self.volatile = volatile
        self.volatileStartMs = volatileStartMs
    }

    public var confirmedText: String {
        committed.map(\.text).joined(separator: " ")
    }

    public var text: String {
        [confirmedText, volatile]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// A running recognition session. Feed 16 kHz mono Float32 samples as they arrive.
public protocol LiveTranscriber: AnyObject, Sendable {
    var updates: AsyncStream<LiveTranscriptUpdate> { get }
    func feed(_ samples: [Float])
    /// Stop and return the best transcription of everything that was fed.
    func finish() async throws -> TranscriptSegment
    func cancel()
}

/// Speech capabilities the rest of the app depends on. `SpeechEngine` is the FluidAudio
/// implementation; tests use fakes.
public protocol SpeechEngineProtocol: AnyObject, Sendable {
    /// Whether models are loaded and ready.
    var isReady: Bool { get async }

    /// Load models into memory (idempotent). Throws `AlethiaError.modelsNotReady` when files are missing.
    func prepare() async throws

    /// Batch recognition of 16 kHz mono audio with word timings relative to the start of `samples`.
    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment

    /// Recognition of a whole recording on disk (any length). `progress` is 0…1.
    func transcribeFile(_ url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> TranscriptSegment

    /// Start a session that produces live partials.
    func startLiveTranscription() async throws -> LiveTranscriber

    /// Speaker segmentation of 16 kHz mono audio.
    func diarize(_ samples: [Float], progress: (@Sendable (Double) -> Void)?) async throws -> [SpeakerSegment]

    /// Voice-activity segments (milliseconds) of 16 kHz mono audio.
    func speechRanges(_ samples: [Float]) async throws -> [ClosedRange<Int>]

    /// Release model memory.
    func unload() async
}

/// Energy-based speech detection used when the VAD model is unavailable and for cheap
/// pause detection in live sessions.
public enum EnergyVAD {
    /// Speech ranges (ms) using a smoothed RMS threshold.
    public static func speechRanges(_ samples: [Float], sampleRate: Int = 16_000, frameMs: Int = 30,
                                    thresholdDb: Float = -42, minSilenceMs: Int = 500, minSpeechMs: Int = 200) -> [ClosedRange<Int>] {
        let frame = max(1, sampleRate * frameMs / 1000)
        guard samples.count >= frame else { return [] }
        var active: [Bool] = []
        var index = 0
        while index + frame <= samples.count {
            var sum: Float = 0
            for i in index..<(index + frame) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(frame)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            active.append(db > thresholdDb)
            index += frame
        }
        var ranges: [ClosedRange<Int>] = []
        var start: Int?
        var silence = 0
        for (i, isActive) in active.enumerated() {
            if isActive {
                if start == nil { start = i }
                silence = 0
            } else if let s = start {
                silence += 1
                if silence * frameMs >= minSilenceMs {
                    let endFrame = i - silence + 1
                    if (endFrame - s) * frameMs >= minSpeechMs {
                        ranges.append((s * frameMs)...(endFrame * frameMs))
                    }
                    start = nil
                    silence = 0
                }
            }
        }
        if let s = start, (active.count - s) * frameMs >= minSpeechMs {
            ranges.append((s * frameMs)...(active.count * frameMs))
        }
        return ranges
    }

    /// Index of the last sample that starts a silence of at least `minSilenceMs`, or nil.
    public static func lastSilenceStart(in samples: [Float], sampleRate: Int = 16_000, minSilenceMs: Int = 400,
                                        thresholdDb: Float = -42) -> Int? {
        let frame = sampleRate * 20 / 1000
        let needed = max(1, minSilenceMs / 20)
        guard samples.count >= frame * needed else { return nil }
        var quiet = 0
        var index = samples.count - frame
        while index >= 0 {
            var sum: Float = 0
            for i in index..<(index + frame) { sum += samples[i] * samples[i] }
            let db = 20 * log10(max((sum / Float(frame)).squareRoot(), 1e-7))
            if db <= thresholdDb {
                quiet += 1
                if quiet >= needed { return index }
            } else {
                // Only accept a silence that is followed by speech again (i.e. mid-utterance pause)
                // or reaches the end; either way a run counted so far is a candidate only if long enough.
                quiet = 0
            }
            index -= frame
        }
        return nil
    }
}

/// Splits a long recording into chunks at silences.
public enum SpeechChunker {
    public static func chunkRanges(totalSamples: Int, sampleRate: Int, speechRangesMs: [ClosedRange<Int>],
                                   maxChunkSamples: Int, minChunkSamples: Int? = nil) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        guard totalSamples > maxChunkSamples else { return [0..<totalSamples] }
        let minChunk = minChunkSamples ?? max(sampleRate * 5, maxChunkSamples / 6)

        var cuts: [Int] = []
        let sorted = speechRangesMs.sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.lowerBound > a.upperBound {
            let midMs = (a.upperBound + b.lowerBound) / 2
            cuts.append(midMs * sampleRate / 1000)
        }
        cuts = cuts.filter { $0 > 0 && $0 < totalSamples }.sorted()

        var ranges: [Range<Int>] = []
        var start = 0
        while totalSamples - start > maxChunkSamples {
            let limit = start + maxChunkSamples
            let candidate = cuts.last { $0 <= limit && $0 >= start + minChunk }
            let end = candidate ?? limit
            ranges.append(start..<end)
            start = end
        }
        if start < totalSamples {
            ranges.append(start..<totalSamples)
        }
        return ranges
    }
}
