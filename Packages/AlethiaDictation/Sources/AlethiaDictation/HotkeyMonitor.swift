import AppKit
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

    /// Legacy: Right Option (Alt) hold — keyCode 61.
    public static let rightOptionHold = HotkeyChord(keyCode: 61, modifiers: [.option], isFnHold: false)
}

@MainActor
public final class HotkeyMonitor: HotkeyMonitoring {
    public var onBegin: (() -> Void)?
    public var onEnd: (() -> Void)?

    public var chord: HotkeyChord
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isDown = false

    public init(chord: HotkeyChord = .fnHold) {
        self.chord = chord
    }

    public func start() {
        stop()
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handle(event)
            return event
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: handler)
        // Global monitor only delivers events when Accessibility is granted.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    public func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if isDown {
            isDown = false
            onEnd?()
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if chord.isFnHold {
            guard event.type == .flagsChanged else { return }
            // Fn/Globe: keyCode 63, or any flagsChanged where .function toggles.
            let isFnKey = event.keyCode == chord.keyCode || event.keyCode == 63
            guard isFnKey || flags.contains(.function) || isDown else { return }
            let fnDown = flags.contains(.function)
            if fnDown, !isDown {
                isDown = true
                onBegin?()
            } else if !fnDown, isDown {
                isDown = false
                onEnd?()
            }
            return
        }

        if event.type == .flagsChanged {
            guard event.keyCode == chord.keyCode else { return }
            let optionDown = flags.contains(.option)
            if optionDown, !isDown {
                isDown = true
                onBegin?()
            } else if !optionDown, isDown {
                isDown = false
                onEnd?()
            }
            return
        }

        let mods = flags.intersection([.command, .option, .control, .shift])
        let wanted = chord.modifiers.intersection([.command, .option, .control, .shift])
        guard mods == wanted, event.keyCode == chord.keyCode else { return }
        if event.type == .keyDown, !event.isARepeat, !isDown {
            isDown = true
            onBegin?()
        } else if event.type == .keyUp, isDown {
            isDown = false
            onEnd?()
        }
    }
}
