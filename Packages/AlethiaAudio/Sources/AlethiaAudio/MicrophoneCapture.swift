import AVFoundation
import Foundation
import AlethiaCore

@MainActor
public protocol AudioCapturing: AnyObject {
    var isRunning: Bool { get }
    func start() throws
    func stop()
    var onFrames: (([Float]) -> Void)? { get set }
}

/// Microphone capture via AVAudioEngine, resampled toward 16 kHz mono Float32.
@MainActor
public final class MicrophoneCapture: AudioCapturing {
    public private(set) var isRunning = false
    public var onFrames: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let targetSampleRate: Double

    public init(targetSampleRate: Double = 16_000) {
        self.targetSampleRate = targetSampleRate
    }

    public func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw AlethiaError.audioEngine("Invalid input format")
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let mono = Self.monoFloats(from: buffer)
            let resampled = Self.resample(mono, from: format.sampleRate, to: self.targetSampleRate)
            self.onFrames?(resampled)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private static func monoFloats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frameLength))
        }
        var mono = [Float](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            var sum: Float = 0
            for c in 0..<channels { sum += data[c][i] }
            mono[i] = sum / Float(channels)
        }
        return mono
    }

    /// Linear resampler sufficient for gating; production may use AVAudioConverter.
    private static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, to > 0, abs(from - to) > 1 else { return input }
        let ratio = to / from
        let outCount = max(Int(Double(input.count) * ratio), 0)
        guard outCount > 0, !input.isEmpty else { return [] }
        var output = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let src = Double(i) / ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, input.count - 1)
            let t = Float(src - Double(i0))
            output[i] = input[i0] * (1 - t) + input[i1] * t
        }
        return output
    }
}
