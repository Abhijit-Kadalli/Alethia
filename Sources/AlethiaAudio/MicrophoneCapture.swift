#if canImport(AVFoundation) && os(macOS)
import AVFoundation
import Foundation
import AlethiaCore

/// Captures the default input device and delivers 16 kHz mono Float32 frames.
///
/// Uses `AVAudioConverter` for proper sample-rate conversion (the input device is usually
/// 44.1/48 kHz) and restarts automatically when the default device changes.
public final class MicrophoneCapture: @unchecked Sendable {
    public let targetSampleRate: Double
    /// Called on the audio thread.
    public var onFrames: (([Float]) -> Void)?
    public var onError: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat
    private var configurationObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var running = false
    private let log = Log("audio.mic")

    public init(targetSampleRate: Double = 16_000) {
        self.targetSampleRate = targetSampleRate
        self.outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)
            ?? AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func start() throws {
        lock.lock()
        if running { lock.unlock(); return }
        lock.unlock()
        try installTapAndStart()
        lock.lock()
        running = true
        lock.unlock()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AlethiaError.audioEngine("No usable microphone input format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AlethiaError.audioEngine("Cannot convert \(Int(inputFormat.sampleRate)) Hz input to \(Int(targetSampleRate)) Hz")
        }
        self.converter = converter
        let ratio = targetSampleRate / inputFormat.sampleRate

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = out.floatChannelData else {
                if let error { self.log.warning("converter error: \(error.localizedDescription)") }
                return
            }
            let count = Int(out.frameLength)
            guard count > 0 else { return }
            self.onFrames?(Array(UnsafeBufferPointer(start: channel[0], count: count)))
        }
        engine.prepare()
        try engine.start()
    }

    private func handleConfigurationChange() {
        lock.lock()
        let shouldRestart = running
        lock.unlock()
        guard shouldRestart else { return }
        log.info("input configuration changed; restarting capture")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            log.error("restart failed: \(error.localizedDescription)")
            onError?(error)
        }
    }
}
#endif
