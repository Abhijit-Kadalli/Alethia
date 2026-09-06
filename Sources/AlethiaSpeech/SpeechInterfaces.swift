import Foundation
import AlethiaCore

/// Partial result while audio is still arriving.
public struct LiveTranscriptUpdate: Sendable, Equatable {
    /// Text the recognizer will not revise anymore.
    public var confirmed: String
    /// Trailing text that may still change.
    public var volatile: String

    public init(confirmed: String = "", volatile: String = "") {
        self.confirmed = confirmed
        self.volatile = volatile
    }

    public var text: String {
        [confirmed, volatile]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// A running low-latency recognition session. Feed 16 kHz mono Float32 samples.
public protocol LiveTranscriber: AnyObject, Sendable {
    var updates: AsyncStream<LiveTranscriptUpdate> { get }
    func feed(_ samples: [Float])
    /// Flush and return the final text.
    func finish() async throws -> String
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

    /// Start a low-latency session for live partials.
    func startLiveTranscription() async throws -> LiveTranscriber

    /// Speaker segmentation of 16 kHz mono audio.
    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment]

    /// Voice-activity segments (milliseconds) of 16 kHz mono audio.
    func speechRanges(_ samples: [Float]) async throws -> [ClosedRange<Int>]

    /// Release model memory.
    func unload() async
}

public extension SpeechEngineProtocol {
    /// Transcribe long audio by splitting on silence so each request stays within the
    /// recognizer's comfortable window. Word timings are shifted back to recording time.
    func transcribeLong(_ samples: [Float], sampleRate: Int = 16_000, maxChunkSeconds: Int = 90,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }
        let maxChunk = maxChunkSeconds * sampleRate
        var ranges: [Range<Int>] = []
        if samples.count <= maxChunk {
            ranges = [0..<samples.count]
        } else {
            let speech = (try? await speechRanges(samples)) ?? []
            ranges = SpeechChunker.chunkRanges(totalSamples: samples.count, sampleRate: sampleRate,
                                               speechRangesMs: speech, maxChunkSamples: maxChunk)
        }
        var result: [TranscriptSegment] = []
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let piece = Array(samples[range])
            var segment = try await transcribe(piece)
            let offsetMs = range.lowerBound * 1000 / sampleRate
            segment.startMs += offsetMs
            segment.endMs += offsetMs
            segment.words = segment.words.map { w in
                TimedWord(text: w.text, startMs: w.startMs + offsetMs, endMs: w.endMs + offsetMs, confidence: w.confidence)
            }
            if !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(segment)
            }
            progress?(Double(index + 1) / Double(ranges.count))
        }
        return result
    }
}

/// Splits a long recording into chunks at silences.
public enum SpeechChunker {
    public static func chunkRanges(totalSamples: Int, sampleRate: Int, speechRangesMs: [ClosedRange<Int>],
                                   maxChunkSamples: Int, minChunkSamples: Int? = nil) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        guard totalSamples > maxChunkSamples else { return [0..<totalSamples] }
        let minChunk = minChunkSamples ?? max(sampleRate * 5, maxChunkSamples / 6)

        // Candidate cut points: midpoints of gaps between speech ranges.
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
            // Best silence cut inside (start + minChunk, limit].
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
