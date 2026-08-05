import AppKit
import Foundation
import SwiftUI
import AlethiaASR
import AlethiaAudio
import AlethiaCore
import AlethiaDiarization
import AlethiaDictation
import AlethiaKnowledge

extension Notification.Name {
    static let alethiaOpenHub = Notification.Name("alethia.openHub")
}

@main
struct AlethiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("Alethia", systemImage: appModel.menuBarSymbol) {
            MenuBarView()
                .environmentObject(appModel)
                .background(OpenWindowRegistrar())
        }
        .menuBarExtraStyle(.window)

        Window("Alethia", id: "hub") {
            HubView()
                .environmentObject(appModel)
                .frame(minWidth: 760, minHeight: 520)
                .background(HubWindowLifecycle())
        }
        .defaultSize(width: 900, height: 600)
    }
}

/// SPM `swift run` binaries are not .app bundles; force accessory policy so MenuBarExtra
/// actually installs a status item instead of behaving like a headless CLI process.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var openWindow: OpenWindowAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenHub),
            name: .alethiaOpenHub,
            object: nil
        )
    }

    @objc private func handleOpenHub() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "hub")
        DispatchQueue.main.async {
            Self.frontHubWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.frontHubWindow()
        }
    }

    static func frontHubWindow() {
        for window in NSApp.windows {
            let id = window.identifier?.rawValue ?? ""
            if id.contains("hub") || window.title == "Alethia" {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    static func hubDidClose() {
        let hubOpen = NSApp.windows.contains {
            let id = $0.identifier?.rawValue ?? ""
            return (id.contains("hub") || $0.title == "Alethia") && $0.isVisible
        }
        if !hubOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct OpenWindowRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { AppDelegate.shared?.openWindow = openWindow }
            .task {
                AppDelegate.shared?.openWindow = openWindow
            }
    }
}

private struct HubWindowLifecycle: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                AppDelegate.frontHubWindow()
            }
            .onDisappear {
                AppDelegate.hubDidClose()
            }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var recordingState: RecordingState = .stopped
    @Published var sessions: [ConversationSession] = []
    @Published var speakers: [SpeakerProfile] = []
    @Published var searchHits: [KnowledgeHit] = []
    @Published var statusMessage: String = "Ready"
    @Published var isDictating = false
    @Published var isTranscribingDictation = false
    @Published var includeSystemAudio = true
    @Published var isTranscribingMeeting = false

    let store: KnowledgeStore
    let meeting: MeetingRecorder
    let dictationMic = DictationMicCapture()
    let asr: ASRService
    let dictation: DictationController
    let gallery: SpeakerGallery
    let diarizer: DiarizationService
    let permissions = PermissionGate()
    let hotkey = HotkeyMonitor()
    let overlay = DictationOverlayController()

    var menuBarSymbol: String {
        if isTranscribingDictation || isTranscribingMeeting { return "hourglass" }
        if isDictating { return "mic.fill" }
        switch recordingState {
        case .recording: return "record.circle.fill"
        case .stopped: return "waveform.circle"
        }
    }

    init() {
        do {
            let store = try KnowledgeStore()
            self.store = store
            self.asr = ASRService()
            self.dictation = DictationController(asr: asr, store: store, permissions: permissions)
            self.gallery = try SpeakerGallery(store: store)
            self.diarizer = DiarizationService(gallery: gallery, embedder: ECAPAGGMLEmbedder())
            self.meeting = MeetingRecorder(includeSystemAudio: true)
            meeting.onPCM = { [weak self] samples in
                self?.routePCM(samples)
            }
            dictationMic.onPCM = { [weak self] samples in
                self?.routePCM(samples)
            }
            wireHotkey()
            reload()
            Task { await self.bootstrapASR() }
        } catch {
            fatalError("Failed to start Alethia: \(error)")
        }
    }

    private func routePCM(_ samples: [Float]) {
        guard isDictating || dictation.isDictating else { return }
        dictation.appendPCM(samples)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        overlay.updateLevel(rms)
    }

    private func bootstrapASR() async {
        _ = await CrisperSidecarLauncher.ensureRunning()
        await refreshStatus()
    }

    private func refreshStatus() async {
        let asrOK = await CrisperWhisperRecognizer.isHealthy()
        let axOK = permissions.accessibilityTrusted(prompt: false)
        var parts: [String] = []
        parts.append(asrOK ? "ASR: CrisperWhisper" : "ASR: offline — run ./Scripts/setup-crisperwhisper.sh")
        parts.append(axOK ? "AX: on" : "AX: off (menu dictation works; Fn+auto-paste need AX)")
        statusMessage = parts.joined(separator: " · ")
    }

    private func wireHotkey() {
        hotkey.onBegin = { [weak self] in self?.beginDictation() }
        hotkey.onEnd = { [weak self] in self?.endDictation() }
        hotkey.start()
    }

    func reload() {
        sessions = (try? store.recentSessions()) ?? []
        speakers = (try? store.allSpeakers()) ?? []
    }

    func toggleMeetingRecording() {
        Task {
            do {
                if recordingState == .stopped {
                    try await permissions.requireMicrophone()
                    meeting.includeSystemAudio = includeSystemAudio
                    try meeting.start()
                    recordingState = .recording
                    statusMessage = includeSystemAudio
                        ? "Recording meeting (mic + system audio)…"
                        : "Recording meeting (mic)…"
                } else {
                    statusMessage = "Transcribing meeting…"
                    isTranscribingMeeting = true
                    let capture = meeting.stop()
                    recordingState = .stopped
                    if let capture {
                        await finalizeMeeting(capture)
                    } else {
                        statusMessage = "Meeting stopped (no audio captured)"
                        await refreshStatus()
                    }
                    isTranscribingMeeting = false
                }
            } catch {
                isTranscribingMeeting = false
                recordingState = meeting.state
                statusMessage = error.localizedDescription
            }
        }
    }

    func beginDictation() {
        Task {
            do {
                guard !isDictating else { return }
                try await permissions.requireMicrophone()
                if !(await CrisperWhisperRecognizer.isHealthy()) {
                    statusMessage = "Starting ASR…"
                    let up = await CrisperSidecarLauncher.ensureRunning()
                    guard up else {
                        statusMessage = "ASR offline — run ./Scripts/run-app.sh"
                        return
                    }
                }
                // Prefer shared meeting stream; otherwise start mic-only capture.
                if recordingState != .recording, !dictationMic.isRunning {
                    try dictationMic.start()
                }
                try dictation.begin()
                isDictating = true
                overlay.show(phase: .listening)
                statusMessage = "Dictating… speak, then release Fn (or Finish)"
            } catch {
                isDictating = false
                overlay.hide()
                if recordingState != .recording {
                    dictationMic.stop()
                }
                statusMessage = error.localizedDescription
            }
        }
    }

    func endDictation() {
        Task {
            guard isDictating || dictation.isDictating else { return }
            // Stop accepting new mic frames, but keep overlay while ASR runs.
            isDictating = false
            isTranscribingDictation = true
            overlay.setPhase(.transcribing)
            statusMessage = "Transcribing…"
            if recordingState != .recording {
                dictationMic.stop()
            }
            do {
                if !(await CrisperWhisperRecognizer.isHealthy()) {
                    _ = await CrisperSidecarLauncher.ensureRunning()
                }
                let event = try await dictation.end(
                    targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                )
                isTranscribingDictation = false
                overlay.hide()
                if dictation.lastPasteNeedsManual {
                    statusMessage = "Copied — press ⌘V (enable Accessibility for auto-paste): “\(event.text.prefix(48))”"
                } else {
                    statusMessage = "Dictated: \(event.text.prefix(64))"
                }
                reload()
            } catch {
                isTranscribingDictation = false
                overlay.hide()
                statusMessage = error.localizedDescription
            }
        }
    }

    func search(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchHits = []
            return
        }
        searchHits = (try? store.search(query: query)) ?? []
    }

    func renameSpeaker(_ speaker: SpeakerProfile, to name: String) {
        do {
            try gallery.rename(id: speaker.id, to: name)
            reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func finalizeMeeting(_ capture: MeetingCapture) async {
        do {
            let transcripts = try await asr.transcribe(
                pcm: capture.pcm,
                sampleRate: capture.sampleRate,
                mode: .verbatim
            )
            let diarized = try diarizer.diarize(
                pcm: capture.pcm,
                sampleRate: capture.sampleRate,
                transcripts: transcripts.map { ($0.startMs, $0.endMs, $0.text) }
            )
            var session = ConversationSession(
                title: "Meeting",
                startedAt: capture.startedAt,
                endedAt: capture.endedAt,
                source: includeSystemAudio ? .mixed : .meeting,
                utterances: diarized.map {
                    Utterance(
                        speakerID: $0.speakerID,
                        speakerLabel: $0.speakerLabel,
                        startMs: $0.startMs,
                        endMs: $0.endMs,
                        text: $0.text
                    )
                }
            )
            if let first = session.utterances.first {
                session.title = String(first.text.prefix(48))
            }
            try store.saveSession(session)
            statusMessage = "Meeting saved"
            reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
