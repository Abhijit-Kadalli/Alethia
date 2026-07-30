import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import AlethiaCore

/// Captures system audio (meetings, Zoom, etc.) without joining a bot.
@MainActor
public final class SystemAudioCapture: NSObject, AudioCapturing {
    public private(set) var isRunning = false
    public var onFrames: (([Float]) -> Void)?

    private var stream: SCStream?
    private let targetSampleRate: Double
    private let sampleQueue = DispatchQueue(label: "app.alethia.system-audio")

    public init(targetSampleRate: Double = 16_000) {
        self.targetSampleRate = targetSampleRate
    }

    public func start() throws {
        guard !isRunning else { return }
        Task {
            do {
                try await startStreaming()
            } catch {
                // Surface via audio engine error path on next stop/start from UI.
                print("SystemAudioCapture failed: \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        stream?.stopCapture { _ in }
        stream = nil
        isRunning = false
    }

    private func startStreaming() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AlethiaError.audioEngine("No display available for system audio capture")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(targetSampleRate)
        config.channelCount = 1
        // Minimal video to satisfy stream; we only consume audio.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        self.isRunning = true
    }
}

extension SystemAudioCapture: SCStreamOutput {
    nonisolated public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let pcm = Self.monoFloats(from: sampleBuffer) else { return }
        Task { @MainActor in
            self.onFrames?(pcm)
        }
    }

    nonisolated private static func monoFloats(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return nil
        }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)

        if asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32, (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
            let count = length / MemoryLayout<Float>.size
            return data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        }
        return nil
    }
}

/// Mixes microphone + optional system audio into one mono callback stream.
@MainActor
public final class MixedAudioCapture: AudioCapturing {
    public var onFrames: (([Float]) -> Void)?
    public private(set) var isRunning = false

    private let microphone: MicrophoneCapture
    private let systemAudio: SystemAudioCapture
    private let includeSystemAudio: Bool

    public init(includeSystemAudio: Bool = true, targetSampleRate: Double = 16_000) {
        self.includeSystemAudio = includeSystemAudio
        self.microphone = MicrophoneCapture(targetSampleRate: targetSampleRate)
        self.systemAudio = SystemAudioCapture(targetSampleRate: targetSampleRate)
    }

    public func start() throws {
        guard !isRunning else { return }
        microphone.onFrames = { [weak self] frames in self?.onFrames?(frames) }
        try microphone.start()
        if includeSystemAudio {
            systemAudio.onFrames = { [weak self] frames in self?.onFrames?(frames) }
            try systemAudio.start()
        }
        isRunning = true
    }

    public func stop() {
        microphone.stop()
        systemAudio.stop()
        isRunning = false
    }
}
