import AppKit
import Foundation

public struct HotkeyChord: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: NSEvent.ModifierFlags

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Right Option (Alt) hold — good default that avoids stealing Cmd shortcuts.
    public static let rightOptionHold = HotkeyChord(keyCode: 61, modifiers: [.option])
}

@MainActor
public final class HotkeyMonitor: HotkeyMonitoring {
    public var onBegin: (() -> Void)?
    public var onEnd: (() -> Void)?

    public var chord: HotkeyChord
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isDown = false

    public init(chord: HotkeyChord = .rightOptionHold) {
        self.chord = chord
    }

    public func start() {
        stop()
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handle(event)
            return event
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: handler)
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
        // Hold-to-talk on Right Option: flagsChanged with option.
        if event.type == .flagsChanged {
            let optionDown = event.modifierFlags.contains(.option)
            if optionDown, !isDown {
                isDown = true
                onBegin?()
            } else if !optionDown, isDown {
                isDown = false
                onEnd?()
            }
            return
        }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
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
