#if canImport(ScreenCaptureKit) && os(macOS)
import CoreMedia
import Foundation
import ScreenCaptureKit
import AlethiaCore

/// Captures everything the Mac plays (call participants in Zoom, Meet, Teams, …) via
/// ScreenCaptureKit's audio-only stream. Requires Screen Recording permission; no video
/// frames are consumed or stored.
public final class SystemAudioCapture: NSObject, @unchecked Sendable {
    public let targetSampleRate: Int
    /// Called on the capture queue.
    public var onFrames: (([Float]) -> Void)?
    public var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.alethia.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private let log = Log("audio.system")

    public init(targetSampleRate: Int = 16_000) {
        self.targetSampleRate = targetSampleRate
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func start() async throws {
        lock.lock()
        if running { lock.unlock(); return }
        lock.unlock()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw AlethiaError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            throw AlethiaError.audioEngine("No display available for system audio capture")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = targetSampleRate
        config.channelCount = 1
        // The stream insists on a video track; keep it as cheap as possible and never read it.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()

        lock.lock()
        self.stream = stream
        running = true
        lock.unlock()
    }

    public func stop() async {
        lock.lock()
        let current = stream
        stream = nil
        running = false
        lock.unlock()
        guard let current else { return }
        do {
            try await current.stopCapture()
        } catch {
            log.warning("stopCapture: \(error.localizedDescription)")
        }
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = Self.monoFloats(from: sampleBuffer) else { return }
        onFrames?(samples)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        self.stream = nil
        running = false
        lock.unlock()
        log.error("system audio stream stopped: \(error.localizedDescription)")
        onError?(error)
    }

    /// Averages all channels of a Float32 (interleaved or planar) or Int16 sample buffer.
    static func monoFloats(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
        let frames = sampleBuffer.numSamples
        guard frames > 0 else { return nil }
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard asbd.mFormatID == kAudioFormatLinearPCM, (isFloat && bits == 32) || (!isFloat && bits == 16) else {
            return nil
        }

        var mono = [Float](repeating: 0, count: frames)
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                let buffers = Array(list)
                if isNonInterleaved {
                    // One buffer per channel.
                    var used = 0
                    for buffer in buffers {
                        guard let raw = buffer.mData else { continue }
                        let available = Int(buffer.mDataByteSize) / (isFloat ? 4 : 2)
                        let n = min(frames, available)
                        if isFloat {
                            let p = raw.assumingMemoryBound(to: Float.self)
                            for i in 0..<n { mono[i] += p[i] }
                        } else {
                            let p = raw.assumingMemoryBound(to: Int16.self)
                            for i in 0..<n { mono[i] += Float(p[i]) / Float(Int16.max) }
                        }
                        used += 1
                    }
                    if used > 1 {
                        let scale = 1 / Float(used)
                        for i in 0..<frames { mono[i] *= scale }
                    }
                } else if let buffer = buffers.first, let raw = buffer.mData {
                    let available = Int(buffer.mDataByteSize) / ((isFloat ? 4 : 2) * channels)
                    let n = min(frames, available)
                    let scale = 1 / Float(channels)
                    if isFloat {
                        let p = raw.assumingMemoryBound(to: Float.self)
                        for i in 0..<n {
                            var sum: Float = 0
                            for c in 0..<channels { sum += p[i * channels + c] }
                            mono[i] = sum * scale
                        }
                    } else {
                        let p = raw.assumingMemoryBound(to: Int16.self)
                        for i in 0..<n {
                            var sum: Float = 0
                            for c in 0..<channels { sum += Float(p[i * channels + c]) / Float(Int16.max) }
                            mono[i] = sum * scale
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return mono
    }
}
#endif
