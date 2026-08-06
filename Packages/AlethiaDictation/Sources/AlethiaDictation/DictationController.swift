import AppKit
import ApplicationServices
import Combine
import Foundation
import AlethiaASR
import AlethiaCore
import AlethiaKnowledge

@MainActor
public protocol HotkeyMonitoring: AnyObject {
    var onBegin: (() -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var isDictating = false
    @Published public private(set) var lastText: String = ""
    /// True when last end() put text on the pasteboard but could not auto-insert.
    @Published public private(set) var lastPasteNeedsManual = false
    /// How the last successful insert landed (for status UI).
    @Published public private(set) var lastPasteMethod: String?

    private let asr: ASRService
    private let store: KnowledgeStore
    private let permissions: PermissionGate
    private var pcmBuffer: [Float] = []
    /// App that was focused when dictation started — restored before paste.
    private var targetApp: NSRunningApplication?
    private var targetPID: pid_t?

    /// Called on the main actor immediately before paste (hide overlay, etc.).
    public var willPaste: (() -> Void)?

    public init(asr: ASRService, store: KnowledgeStore, permissions: PermissionGate = PermissionGate()) {
        self.asr = asr
        self.store = store
        self.permissions = permissions
    }

    /// Start capturing. Accessibility is NOT required to record/transcribe — only to auto-paste.
    public func begin(targetApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) throws {
        isDictating = true
        lastPasteNeedsManual = false
        lastPasteMethod = nil
        pcmBuffer.removeAll(keepingCapacity: true)

        let candidate: NSRunningApplication? = {
            if let targetApp, targetApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                return targetApp
            }
            return NSWorkspace.shared.runningApplications.first(where: {
                $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }) ?? NSWorkspace.shared.frontmostApplication
        }()

        if let candidate, candidate.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.targetApp = candidate
            self.targetPID = candidate.processIdentifier
        } else {
            self.targetApp = nil
            self.targetPID = nil
        }
    }

    public func appendPCM(_ samples: [Float]) {
        guard isDictating else { return }
        pcmBuffer.append(contentsOf: samples)
    }

    public var bufferedSampleCount: Int { pcmBuffer.count }

    public func end(targetBundleID: String? = nil) async throws -> DictationEvent {
        let savedTarget = targetApp
        let savedPID = targetPID
        defer {
            isDictating = false
            pcmBuffer.removeAll(keepingCapacity: true)
            targetApp = nil
            targetPID = nil
        }
        let samples = pcmBuffer
        guard samples.count > 1600 else { // ~100ms @ 16kHz
            throw AlethiaError.audioEngine("No mic audio captured — grant Microphone, then use menu Start Dictation")
        }
        // Intended mode for clean paste; Hub meetings use verbatim separately.
        let segments = try await asr.transcribe(pcm: samples, mode: .intended)
        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AlethiaError.audioEngine("No speech detected for dictation")
        }
        if text.contains("local crisperwhisper pending") {
            throw AlethiaError.modelMissing("CrisperWhisper sidecar not running — run Scripts/setup-crisperwhisper.sh")
        }

        // Restore targets for paste (defer cleared after we return; keep locals).
        targetApp = savedTarget
        targetPID = savedPID
        willPaste?()
        let pasted = await insertText(text)
        lastPasteNeedsManual = !pasted

        let event = DictationEvent(
            text: text,
            verbatimText: text,
            targetBundleID: targetBundleID ?? savedTarget?.bundleIdentifier
        )
        try store.saveDictation(event)
        lastText = text
        return event
    }

    /// Copy + restore focus + insert into the previously focused app.
    private func insertText(_ text: String) async -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        if !permissions.accessibilityTrusted(prompt: false) {
            _ = permissions.accessibilityTrusted(prompt: true)
            lastPasteMethod = nil
            return false
        }

        guard await focusTargetApp() else {
            lastPasteMethod = nil
            return false
        }

        // Prefer AX write into the target app's focused field.
        if insertViaAccessibility(text) {
            lastPasteMethod = "accessibility"
            return true
        }

        // Small settle — some Electron apps need a beat after activation.
        try? await Task.sleep(nanoseconds: 80_000_000)
        _ = await focusTargetApp()

        if pasteViaCommandV() {
            lastPasteMethod = "command-v"
            return true
        }

        if insertViaUnicodeEvents(text) {
            lastPasteMethod = "unicode"
            return true
        }

        lastPasteMethod = nil
        return false
    }

    @discardableResult
    private func focusTargetApp() async -> Bool {
        guard let targetApp, !targetApp.isTerminated else {
            // Fall back to whatever is frontmost (not us).
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }

        // macOS 14+ ignores activateIgnoringOtherApps — yield activation explicitly.
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: targetApp)
        }
        NSApp.deactivate()
        targetApp.activate()

        // Wait until the target is frontmost (up to ~750ms).
        for _ in 0..<15 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier {
                try? await Task.sleep(nanoseconds: 60_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: targetApp)
            }
            targetApp.activate()
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier
    }

    private func insertViaAccessibility(_ text: String) -> Bool {
        let focused = focusedElement()
        guard let focused else { return false }

        // 1) Replace / insert at selection.
        if AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            return true
        }

        // 2) Append / set AXValue for classic text fields.
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
           let existing = valueRef as? String {
            let combined = existing + text
            if AXUIElementSetAttributeValue(
                focused,
                kAXValueAttribute as CFString,
                combined as CFTypeRef
            ) == .success {
                return true
            }
        } else if AXUIElementSetAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            return true
        }

        return false
    }

    private func focusedElement() -> AXUIElement? {
        // Prefer the target app's focused element so our overlay / menu bar can't steal it.
        if let pid = targetPID ?? targetApp?.processIdentifier {
            let appEl = AXUIElementCreateApplication(pid)
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appEl,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            ) == .success, let focusedRef {
                return (focusedRef as! AXUIElement)
            }
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    /// Full Command-down → V-down → V-up → Command-up via HID tap (more reliable than a lone flagged V).
    private func pasteViaCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0

        let keyV: CGKeyCode = 9
        let keyCmd: CGKeyCode = 55 // left ⌘

        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCmd, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCmd, keyDown: false)
        else { return false }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        let tap = CGEventTapLocation.cghidEventTap
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
        return true
    }

    private func insertViaUnicodeEvents(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        let utf16 = Array(text.utf16)
        let chunkSize = 16
        var index = 0
        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            chunk.withUnsafeMutableBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
        }
        return true
    }
}
