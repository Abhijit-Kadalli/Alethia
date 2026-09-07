#if canImport(CoreAudio) && os(macOS)
import CoreAudio
import Foundation
import AlethiaCore

/// Watches whether *any* process is using the default input device. When a call starts in
/// Zoom, Meet, Teams, FaceTime, Slack, … the microphone lights up, which is the cue to
/// offer meeting notes — without knowing anything about the app itself.
public final class MicrophoneActivityMonitor: @unchecked Sendable {
    /// Called on `queue` whenever the state flips. `true` means some process is capturing.
    public var onChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "app.alethia.mic-activity")
    private var deviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var lastState = false
    private let lock = NSLock()
    private var running = false
    private let log = Log("audio.activity")

    public init() {}

    deinit {
        stop()
    }

    public var isMicrophoneInUse: Bool {
        Self.isRunningSomewhere(device: Self.defaultInputDevice())
    }

    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()

        attach(to: Self.defaultInputDevice())

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.detach()
            self.attach(to: Self.defaultInputDevice())
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        detach()
        if let defaultDeviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, defaultDeviceListener)
            self.defaultDeviceListener = nil
        }
    }

    private func attach(to device: AudioObjectID) {
        guard device != kAudioObjectUnknown else { return }
        deviceID = device
        var address = Self.runningAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.evaluate()
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        evaluate()
    }

    private func detach() {
        guard deviceID != kAudioObjectUnknown, let deviceListener else { return }
        var address = Self.runningAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, deviceListener)
        self.deviceListener = nil
        deviceID = kAudioObjectUnknown
    }

    private func evaluate() {
        let state = Self.isRunningSomewhere(device: deviceID)
        lock.lock()
        let changed = state != lastState
        lastState = state
        lock.unlock()
        if changed {
            log.debug("microphone in use: \(state)")
            onChange?(state)
        }
    }

    private static var runningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultInputDevice() -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    static func isRunningSomewhere(device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = runningAddress
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}
#endif
