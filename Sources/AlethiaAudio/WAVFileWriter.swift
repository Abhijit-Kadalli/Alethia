import Foundation
import AlethiaCore

/// Streams 16-bit mono PCM to a WAV file as audio arrives, so hour-long meetings never
/// sit in memory. The header is patched with the final sizes on `close()`; if the process
/// dies first, `repairHeader(at:)` fixes the file from its length.
public final class WAVFileWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Int

    private let handle: FileHandle
    private let lock = NSLock()
    private var dataBytes = 0
    private var pending = Data()
    private var closed = false
    private let flushThreshold = 64 * 1024

    public init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AlethiaError.audioEngine("Could not create \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WAVCodec.header(sampleRate: sampleRate, dataBytes: 0))
    }

    public var framesWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return (dataBytes + pending.count) / 2
    }

    public var durationMs: Int {
        framesWritten * 1000 / max(sampleRate, 1)
    }

    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pending.append(WAVCodec.pcm16Bytes(from: samples))
        if pending.count >= flushThreshold {
            try flushLocked()
        }
    }

    public func flush() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try flushLocked()
        try patchHeaderLocked()
    }

    /// Writes remaining samples, finalizes the header and closes the file.
    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try flushLocked()
        try patchHeaderLocked()
        try handle.close()
        closed = true
    }

    private func flushLocked() throws {
        guard !pending.isEmpty else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: pending)
        dataBytes += pending.count
        pending.removeAll(keepingCapacity: true)
    }

    private func patchHeaderLocked() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVCodec.header(sampleRate: sampleRate, dataBytes: dataBytes))
        try handle.synchronize()
    }

    /// Rewrites the RIFF/data sizes of a WAV file from its actual length. Used after a crash.
    public static func repairHeader(at url: URL, sampleRate: Int) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size >= WAVCodec.headerSize else { return }
        let dataBytes = size - WAVCodec.headerSize
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVCodec.header(sampleRate: sampleRate, dataBytes: dataBytes - dataBytes % 2))
    }
}
