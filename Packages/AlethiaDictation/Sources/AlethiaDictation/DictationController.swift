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

    private let asr: ASRService
    private let store: KnowledgeStore
    private let permissions: PermissionGate
    private var pcmBuffer: [Float] = []
    /// App that was focused when dictation started — restored before paste.
    private var targetApp: NSRunningApplication?

    public init(asr: ASRService, store: KnowledgeStore, permissions: PermissionGate = PermissionGate()) {
        self.asr = asr
        self.store = store
        self.permissions = permissions
    }

    /// Start capturing. Accessibility is NOT required to record/transcribe — only to auto-paste.
    public func begin(targetApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) throws {
        isDictating = true
        lastPasteNeedsManual = false
        pcmBuffer.removeAll(keepingCapacity: true)
        // Don't target Alethia itself if the menu bar happened to be frontmost.
        if let targetApp, targetApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.targetApp = targetApp
        } else {
            self.targetApp = NSWorkspace.shared.frontmostApplication
        }
    }

    public func appendPCM(_ samples: [Float]) {
        guard isDictating else { return }
        pcmBuffer.append(contentsOf: samples)
    }

    public var bufferedSampleCount: Int { pcmBuffer.count }

    public func end(targetBundleID: String? = nil) async throws -> DictationEvent {
        defer {
            isDictating = false
            pcmBuffer.removeAll(keepingCapacity: true)
            targetApp = nil
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

        let pasted = await insertText(text)
        lastPasteNeedsManual = !pasted

        let event = DictationEvent(
            text: text,
            verbatimText: text,
            targetBundleID: targetBundleID ?? targetApp?.bundleIdentifier
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
            // Prompt once so the user can enable Alethia.app, then still leave clipboard filled.
            _ = permissions.accessibilityTrusted(prompt: true)
            permissions.openAccessibilitySettings()
            return false
        }

        // Bring the original app back (menu-bar / overlay may have stolen focus).
        if let targetApp, !targetApp.isTerminated {
            targetApp.activate()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Prefer AX insert into the focused field — more reliable than synthetic ⌘V.
        if insertViaAccessibility(text) {
            return true
        }

        // Fallback: clipboard + ⌘V
        if pasteViaCommandV() {
            return true
        }

        // Last resort: inject unicode keystrokes (works in many text fields without AX settable value).
        if insertViaUnicodeEvents(text) {
            return true
        }

        return false
    }

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard status == .success, let focusedRef else { return false }
        let focused = focusedRef as! AXUIElement

        // 1) Replace selection if the control supports AXSelectedText.
        if AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            return true
        }

        // 2) Append / set AXValue for text fields that expose it.
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

    private func pasteViaCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9 // 'v'
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        // Post to annotated session so the frontmost app receives it.
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    private func insertViaUnicodeEvents(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        // CGEvent unicode injection is limited (~20 UTF-16 units per event on some OS versions).
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
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            index = end
        }
        return true
    }
}
