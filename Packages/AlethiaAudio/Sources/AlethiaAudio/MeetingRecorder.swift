import Combine
import Foundation
import AlethiaCore

public struct MeetingCapture: Sendable {
    public var pcm: [Float]
    public var sampleRate: Double
    public var startedAt: Date
    public var endedAt: Date

    public init(pcm: [Float], sampleRate: Double, startedAt: Date, endedAt: Date) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Explicit start/stop meeting capture (mic + optional system audio). No ambient VAD segmentation.
@MainActor
public final class MeetingRecorder: ObservableObject {
    @Published public private(set) var state: RecordingState = .stopped
    @Published public private(set) var lastLevel: Float = 0

    /// Live PCM frames for dictation overlay / dual consumers.
    public var onPCM: (([Float]) -> Void)?

    private var capture: AudioCapturing?
    private var pcmBuffer: [Float] = []
    private var startedAt: Date?
    private let sampleRate: Double = 16_000
    public var includeSystemAudio: Bool = true

    public init(includeSystemAudio: Bool = true) {
        self.includeSystemAudio = includeSystemAudio
    }

    public func start() throws {
        guard state == .stopped else { return }
        pcmBuffer.removeAll(keepingCapacity: true)
        startedAt = Date()
        let mixed = MixedAudioCapture(includeSystemAudio: includeSystemAudio, targetSampleRate: sampleRate)
        mixed.onFrames = { [weak self] samples in
            Task { @MainActor in self?.ingest(samples) }
        }
        try mixed.start()
        capture = mixed
        state = .recording
    }

    /// Stop and return buffered audio (nil if empty / not recording).
    @discardableResult
    public func stop() -> MeetingCapture? {
        guard state == .recording else {
            capture?.stop()
            capture = nil
            state = .stopped
            return nil
        }
        capture?.stop()
        capture = nil
        state = .stopped
        let ended = Date()
        let started = startedAt ?? ended
        startedAt = nil
        let pcm = pcmBuffer
        pcmBuffer.removeAll(keepingCapacity: true)
        guard pcm.count > Int(sampleRate * 0.25) else { return nil }
        return MeetingCapture(pcm: pcm, sampleRate: sampleRate, startedAt: started, endedAt: ended)
    }

    private func ingest(_ samples: [Float]) {
        guard state == .recording else { return }
        pcmBuffer.append(contentsOf: samples)
        if !samples.isEmpty {
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
            lastLevel = rms
        }
        onPCM?(samples)
    }
}

/// Mic-only capture for dictation when no meeting is active.
@MainActor
public final class DictationMicCapture: ObservableObject {
    @Published public private(set) var isRunning = false
    public var onPCM: (([Float]) -> Void)?

    private let microphone = MicrophoneCapture(targetSampleRate: 16_000)

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        microphone.onFrames = { [weak self] samples in
            self?.onPCM?(samples)
        }
        try microphone.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        microphone.stop()
        isRunning = false
    }
}
