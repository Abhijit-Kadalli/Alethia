import AppKit
import ApplicationServices
import Foundation

public struct HotkeyChord: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: NSEvent.ModifierFlags
    /// When true, treat as Fn / Globe hold via `.function` flag (keyCode typically 63).
    public var isFnHold: Bool

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isFnHold: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isFnHold = isFnHold
    }

    /// Hold Fn / Globe (keyCode 63) for push-to-talk dictation.
    public static let fnHold = HotkeyChord(keyCode: 63, modifiers: [], isFnHold: true)

    /// Right Option (Alt) hold — keyCode 61. Reliable fallback when Globe is remapped.
    public static let rightOptionHold = HotkeyChord(keyCode: 61, modifiers: [.option], isFnHold: false)
}

@MainActor
public final class HotkeyMonitor: HotkeyMonitoring {
    public var onBegin: (() -> Void)?
    public var onEnd: (() -> Void)?

    /// Primary chord (Fn by default). Right Option is always also accepted as a fallback.
    public var chord: HotkeyChord
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var isDown = false
    private var activeKind: ActiveKind?

    private enum ActiveKind {
        case fn
        case rightOption
    }

    public init(chord: HotkeyChord = .fnHold) {
        self.chord = chord
    }

    public func start() {
        stop()
        installNSEventMonitors()
        installEventTapIfPossible()
    }

    public func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        tearDownEventTap()
        if isDown {
            isDown = false
            activeKind = nil
            onEnd?()
        }
    }

    // MARK: - NSEvent monitors

    private func installNSEventMonitors() {
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp],
            handler: handler
        )
        // Global monitor only delivers when Accessibility is granted.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            self?.handleNSEvent(event)
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        handleFlags(
            keyCode: event.keyCode,
            functionDown: flags.contains(.function),
            optionDown: flags.contains(.option),
            hasOtherMods: !flags.intersection([.command, .control, .shift]).isEmpty
        )
    }

    // MARK: - CGEvent tap (more reliable for Fn/Globe when AX is on)

    private func installEventTapIfPossible() {
        // Without Accessibility the tap is denied — NSEvent path still works once AX is granted.
        guard AXIsProcessTrusted() else { return }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            guard type == .flagsChanged else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let raw = event.flags
            let functionDown = raw.contains(.maskSecondaryFn)
            let optionDown = raw.contains(.maskAlternate)
            let hasOtherMods = !raw.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty
            DispatchQueue.main.async {
                monitor.handleFlags(
                    keyCode: keyCode,
                    functionDown: functionDown,
                    optionDown: optionDown,
                    hasOtherMods: hasOtherMods
                )
            }
            return Unmanaged.passUnretained(event)
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func tearDownEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTapSource = nil
        eventTap = nil
    }

    /// Re-try installing the CGEvent tap after the user grants Accessibility.
    public func refreshEventTap() {
        tearDownEventTap()
        installEventTapIfPossible()
    }

    // MARK: - Shared flag logic

    private func handleFlags(
        keyCode: UInt16,
        functionDown: Bool,
        optionDown: Bool,
        hasOtherMods: Bool
    ) {
        // Fn / Globe: only the Fn key itself (63 or 0 on some boards), not arrows that set .function.
        let isFnKey = keyCode == 63 || keyCode == 0
        if isFnKey {
            let bareFn = functionDown && !hasOtherMods
            if bareFn, !isDown {
                isDown = true
                activeKind = .fn
                onBegin?()
            } else if !functionDown, isDown, activeKind == .fn {
                isDown = false
                activeKind = nil
                onEnd?()
            }
        }

        // Right Option fallback (and optional primary chord).
        let isRightOption = keyCode == 61
        let wantsRightOption = chord == .rightOptionHold || chord.isFnHold
        if wantsRightOption, isRightOption {
            let bareOption = optionDown && !hasOtherMods
            if bareOption, !isDown {
                isDown = true
                activeKind = .rightOption
                onBegin?()
            } else if !optionDown, isDown, activeKind == .rightOption {
                isDown = false
                activeKind = nil
                onEnd?()
            }
        }
    }
}
