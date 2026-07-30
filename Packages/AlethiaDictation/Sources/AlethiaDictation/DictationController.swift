import AppKit
import ApplicationServices
import Combine
import Foundation
import AlethiaASR
import AlethiaCore
import AlethiaKnowledge

public protocol HotkeyMonitoring: AnyObject {
    var onBegin: (() -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    func start()
    func stop()
}

/// Simple flag-based hotkey controller used until CGEvent taps are wired in the Mac app target.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var isDictating = false
    @Published public private(set) var lastText: String = ""

    private let asr: ASRService
    private let store: KnowledgeStore
    private let permissions: PermissionGate
    private var pcmBuffer: [Float] = []

    public init(asr: ASRService, store: KnowledgeStore, permissions: PermissionGate = PermissionGate()) {
        self.asr = asr
        self.store = store
        self.permissions = permissions
    }

    public func begin() throws {
        try permissions.requireAccessibility(prompt: true)
        isDictating = true
        pcmBuffer.removeAll(keepingCapacity: true)
    }

    public func appendPCM(_ samples: [Float]) {
        guard isDictating else { return }
        pcmBuffer.append(contentsOf: samples)
    }

    public func end(targetBundleID: String? = nil) async throws -> DictationEvent {
        defer {
            isDictating = false
            pcmBuffer.removeAll(keepingCapacity: true)
        }
        let segments = try await asr.transcribe(pcm: pcmBuffer)
        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AlethiaError.audioEngine("No speech detected for dictation")
        }
        try paste(text)
        let event = DictationEvent(text: text, targetBundleID: targetBundleID)
        try store.saveDictation(event)
        lastText = text
        return event
    }

    private func paste(_ text: String) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Cmd+V via CGEvent. Requires Accessibility.
        guard permissions.accessibilityTrusted(prompt: false) else {
            throw AlethiaError.accessibilityPermissionDenied
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
