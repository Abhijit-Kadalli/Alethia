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
    /// True when last end() put text on the pasteboard but could not synthesize ⌘V.
    @Published public private(set) var lastPasteNeedsManual = false

    private let asr: ASRService
    private let store: KnowledgeStore
    private let permissions: PermissionGate
    private var pcmBuffer: [Float] = []

    public init(asr: ASRService, store: KnowledgeStore, permissions: PermissionGate = PermissionGate()) {
        self.asr = asr
        self.store = store
        self.permissions = permissions
    }

    /// Start capturing. Accessibility is NOT required to record/transcribe — only to auto-paste.
    public func begin() throws {
        isDictating = true
        lastPasteNeedsManual = false
        pcmBuffer.removeAll(keepingCapacity: true)
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
        }
        let samples = pcmBuffer
        guard samples.count > 1600 else { // ~100ms @ 16kHz
            throw AlethiaError.audioEngine("No mic audio captured — grant Microphone, then use menu Start Dictation")
        }
        let segments = try await asr.transcribe(pcm: samples)
        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AlethiaError.audioEngine("No speech detected for dictation")
        }
        if text.contains("local crisperwhisper pending") {
            throw AlethiaError.modelMissing("CrisperWhisper sidecar not running — run Scripts/setup-crisperwhisper.sh")
        }

        let pasted = pasteToClipboardAndType(text)
        lastPasteNeedsManual = !pasted

        let event = DictationEvent(text: text, targetBundleID: targetBundleID)
        try store.saveDictation(event)
        lastText = text
        return event
    }

    /// Always copies to clipboard. Returns true if Accessibility ⌘V was posted.
    @discardableResult
    private func pasteToClipboardAndType(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard permissions.accessibilityTrusted(prompt: false) else {
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }
}
