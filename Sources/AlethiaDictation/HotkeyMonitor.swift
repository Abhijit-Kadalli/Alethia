#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import AlethiaCore

/// Watches a single push-to-talk key system-wide using a CGEvent tap.
///
/// Modifier-style keys (Fn, ⌥, ⌘, ⌃) arrive as `flagsChanged`; F5 arrives as key down/up and
/// is swallowed so the target app never sees it. If another key is pressed while the hotkey is
/// held (Fn+F1, ⌥+Tab, …) the press is treated as a shortcut and cancelled.
@MainActor
public final class HotkeyMonitor {
    public enum Event: Sendable, Equatable {
        case pressed
        case released(heldMs: Int)
        case cancelled
    }

    public var hotkey: DictationHotkey {
        didSet { resetPressState() }
    }
    public var onEvent: ((Event) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var pressedAt: Date?
    private var sawOtherKey = false
    private let log = Log("Hotkey")

    public init(hotkey: DictationHotkey) {
        self.hotkey = hotkey
    }

    public var isRunning: Bool { tap != nil }

    /// Requires Accessibility (or Input Monitoring) trust; throws otherwise.
    public func start() throws {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: userInfo
        ) else {
            throw AlethiaError.accessibilityPermissionDenied
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        log.info("event tap installed for \(hotkey.rawValue)")
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        resetPressState()
    }

    private func resetPressState() {
        isDown = false
        pressedAt = nil
        sawOtherKey = false
    }

    // MARK: Event handling (main run loop)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        switch hotkey {
        case .f5:
            guard keyCode == 96 else {
                noteOtherKey(type: type)
                return Unmanaged.passUnretained(event)
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown, !isRepeat {
                keyWentDown()
            } else if type == .keyUp {
                keyWentUp()
            }
            return nil

        case .fn, .rightOption, .rightCommand, .leftControl:
            guard type == .flagsChanged else {
                noteOtherKey(type: type)
                return Unmanaged.passUnretained(event)
            }
            guard keyCode == hotkey.keyCode else {
                if isDown { sawOtherKey = true }
                return Unmanaged.passUnretained(event)
            }
            let down = event.flags.contains(hotkey.flagMask)
            if down, !isDown {
                keyWentDown()
            } else if !down, isDown {
                keyWentUp()
            }
            return Unmanaged.passUnretained(event)
        }
    }

    private func noteOtherKey(type: CGEventType) {
        if isDown, type == .keyDown {
            sawOtherKey = true
        }
    }

    private func keyWentDown() {
        isDown = true
        pressedAt = Date()
        sawOtherKey = false
        onEvent?(.pressed)
    }

    private func keyWentUp() {
        let held = pressedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let combo = sawOtherKey
        resetPressState()
        onEvent?(combo ? .cancelled : .released(heldMs: held))
    }
}

private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    var result: Unmanaged<CGEvent>?
    MainActor.assumeIsolated {
        result = monitor.handle(type: type, event: event)
    }
    return result
}

extension DictationHotkey {
    var keyCode: Int {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .leftControl: return 59
        case .f5: return 96
        }
    }

    var flagMask: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .leftControl: return .maskControl
        case .f5: return []
        }
    }

    /// Symbol shown in the menu bar and overlay.
    public var symbol: String {
        switch self {
        case .fn: return "🌐"
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        case .leftControl: return "⌃"
        case .f5: return "F5"
        }
    }
}
#endif
