#if os(macOS)
import Foundation
import AlethiaCore

/// Result of a finished meeting capture.
public struct MeetingCaptureResult: Sendable {
    public var audioURL: URL
    public var sampleRate: Int
    public var durationMs: Int
    public var startedAt: Date
    public var endedAt: Date
    public var activity: [SourceActivityFrame]
    public var includedSystemAudio: Bool
}

/// Records a meeting: microphone (+ optional system audio) → mixer → WAV on disk, while
/// streaming mixed chunks to a live consumer (the streaming recognizer).
public final class MeetingAudioCapture: @unchecked Sendable {
    public let sampleRate = 16_000
    /// Mixed 100 ms chunks, delivered on an audio thread.
    public var onChunk: ((MixedChunk) -> Void)?
    /// Non-fatal problems (system audio dropped, device changed) for status UI.
    public var onWarning: ((String) -> Void)?

    private let microphone = MicrophoneCapture(targetSampleRate: 16_000)
    private var system: SystemAudioCapture?
    private var mixer: AudioMixer?
    private var writer: WAVFileWriter?
    private var startedAt: Date?
    private var includesSystem = false
    private let lock = NSLock()
    private let log = Log("audio.meeting")

    public init() {}

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return writer != nil
    }

    public var durationMs: Int {
        lock.lock(); defer { lock.unlock() }
        return writer?.durationMs ?? 0
    }

    /// Starts capturing to `url`. If system audio was requested but cannot start (no Screen
    /// Recording permission, no display), recording continues with the microphone only and
    /// `onWarning` is called; the returned flag tells which happened.
    @discardableResult
    public func start(to url: URL, includeSystemAudio: Bool) async throws -> Bool {
        lock.lock()
        if writer != nil { lock.unlock(); return includesSystem }
        lock.unlock()

        var systemCapture: SystemAudioCapture?
        if includeSystemAudio {
            let capture = SystemAudioCapture(targetSampleRate: sampleRate)
            do {
                try await capture.start()
                systemCapture = capture
            } catch {
                log.warning("system audio unavailable: \(error.localizedDescription)")
                onWarning?("System audio unavailable — recording microphone only. \(error.localizedDescription)")
            }
        }

        let writer = try WAVFileWriter(url: url, sampleRate: sampleRate)
        let mixer = AudioMixer(sampleRate: sampleRate, hopMilliseconds: 100, includesSystemAudio: systemCapture != nil)
        mixer.onChunk = { [weak self] chunk in
            guard let self else { return }
            do {
                try writer.append(chunk.samples)
            } catch {
                self.log.error("write failed: \(error.localizedDescription)")
                self.onWarning?("Couldn't write the recording: \(error.localizedDescription)")
            }
            self.onChunk?(chunk)
        }

        microphone.onFrames = { frames in mixer.push(frames, from: .microphone) }
        microphone.onError = { [weak self] error in
            self?.onWarning?("Microphone error: \(error.localizedDescription)")
        }
        systemCapture?.onFrames = { frames in mixer.push(frames, from: .system) }
        systemCapture?.onError = { [weak self] error in
            self?.onWarning?("System audio stopped: \(error.localizedDescription)")
        }

        do {
            try microphone.start()
        } catch {
            await systemCapture?.stop()
            try? writer.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        lock.lock()
        self.writer = writer
        self.mixer = mixer
        self.system = systemCapture
        self.startedAt = Date()
        self.includesSystem = systemCapture != nil
        lock.unlock()
        return systemCapture != nil
    }

    public func stop() async -> MeetingCaptureResult? {
        lock.lock()
        guard let writer, let mixer else { lock.unlock(); return nil }
        let system = self.system
        let started = startedAt ?? Date()
        let includedSystem = includesSystem
        self.writer = nil
        self.mixer = nil
        self.system = nil
        self.startedAt = nil
        lock.unlock()

        microphone.stop()
        await system?.stop()
        mixer.flush()
        do {
            try writer.close()
        } catch {
            log.error("close failed: \(error.localizedDescription)")
        }
        return MeetingCaptureResult(
            audioURL: writer.url,
            sampleRate: sampleRate,
            durationMs: writer.durationMs,
            startedAt: started,
            endedAt: Date(),
            activity: mixer.activityTimeline,
            includedSystemAudio: includedSystem
        )
    }
}

/// Microphone-only capture for dictation. Keeps the whole utterance in memory (bounded)
/// and streams frames to a live consumer.
public final class DictationAudioCapture: @unchecked Sendable {
    public let sampleRate = 16_000
    /// Raw 16 kHz frames as they arrive (audio thread).
    public var onFrames: (([Float]) -> Void)?
    /// Hard cap so a stuck hotkey cannot grow memory forever (20 minutes).
    public let maxSamples = 16_000 * 60 * 20

    private let microphone = MicrophoneCapture(targetSampleRate: 16_000)
    private var buffer: [Float] = []
    private let lock = NSLock()
    private var startedAt: Date?

    public init() {}

    public var isRunning: Bool { microphone.isRunning }

    public var bufferedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    public func start() throws {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(sampleRate * 30)
        startedAt = Date()
        lock.unlock()
        microphone.onFrames = { [weak self] frames in
            guard let self else { return }
            self.lock.lock()
            let accept = self.buffer.count < self.maxSamples
            if accept {
                self.buffer.append(contentsOf: frames)
            }
            self.lock.unlock()
            if accept {
                self.onFrames?(frames)
            }
        }
        try microphone.start()
    }

    /// Stops capture and returns everything recorded since `start()`.
    public func stop() -> (samples: [Float], durationMs: Int) {
        microphone.stop()
        lock.lock()
        let samples = buffer
        buffer.removeAll(keepingCapacity: true)
        startedAt = nil
        lock.unlock()
        return (samples, samples.count * 1000 / sampleRate)
    }
}
#endif
