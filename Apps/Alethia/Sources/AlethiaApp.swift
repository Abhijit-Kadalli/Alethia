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
    @Published var dictations: [DictationEvent] = []
    @Published var selectedMeetingID: UUID?
    @Published var speakers: [SpeakerProfile] = []
    @Published var searchHits: [KnowledgeHit] = []
    @Published var statusMessage: String = "Ready"
    @Published var isDictating = false
    @Published var isTranscribingDictation = false
    @Published var includeSystemAudio = true
    @Published var isTranscribingMeeting = false
    /// Hub transcript display: verbatim (what was said) vs intended (cleaned).
    @Published var hubShowVerbatim = true
    /// Hub: show per-word timestamps under each utterance.
    @Published var hubShowWordTimings = false

    var selectedMeeting: ConversationSession? {
        guard let selectedMeetingID else { return sessions.first }
        return sessions.first(where: { $0.id == selectedMeetingID }) ?? sessions.first
    }

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
        dictations = (try? store.recentDictations()) ?? []
        speakers = (try? store.allSpeakers()) ?? []
        if selectedMeetingID == nil {
            selectedMeetingID = sessions.first?.id
        } else if let id = selectedMeetingID, !sessions.contains(where: { $0.id == id }) {
            selectedMeetingID = sessions.first?.id
        }
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
                try dictation.begin(targetApp: NSWorkspace.shared.frontmostApplication)
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
                    statusMessage = "Copied — enable Accessibility for Alethia.app, then ⌘V: “\(event.text.prefix(48))”"
                    permissions.openAccessibilitySettings()
                } else {
                    statusMessage = "Pasted: \(event.text.prefix(64))"
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
            async let verbatimTask = asr.transcribe(
                pcm: capture.pcm,
                sampleRate: capture.sampleRate,
                mode: .verbatim,
                wordTimestamps: true
            )
            async let intendedTask = asr.transcribe(
                pcm: capture.pcm,
                sampleRate: capture.sampleRate,
                mode: .intended,
                wordTimestamps: true
            )
            let transcripts = try await verbatimTask
            let intended = (try? await intendedTask) ?? []
            let allWords = transcripts.flatMap(\.words)

            let diarized = try diarizer.diarize(
                pcm: capture.pcm,
                sampleRate: capture.sampleRate,
                transcripts: transcripts.map { ($0.startMs, $0.endMs, $0.text) },
                intendedTranscripts: intended.map { ($0.startMs, $0.endMs, $0.text) }
            )

            var utterances = diarized.map { d in
                let words = allWords.filter { w in
                    w.startMs >= d.startMs && w.startMs < max(d.endMs, d.startMs + 1)
                }
                return Utterance(
                    speakerID: d.speakerID,
                    speakerLabel: d.speakerLabel,
                    startMs: d.startMs,
                    endMs: d.endMs,
                    text: d.text,
                    intendedText: d.intendedText,
                    words: words
                )
            }
            if utterances.isEmpty {
                utterances = transcripts.map {
                    Utterance(
                        startMs: $0.startMs,
                        endMs: $0.endMs,
                        text: $0.text,
                        words: $0.words
                    )
                }
            } else if utterances.allSatisfy(\.words.isEmpty), !allWords.isEmpty {
                // Fallback: attach all words to the single span / distribute by time.
                for i in utterances.indices {
                    utterances[i].words = allWords.filter {
                        $0.startMs >= utterances[i].startMs && $0.startMs < max(utterances[i].endMs, utterances[i].startMs + 1)
                    }
                }
            }
            // If intended came back as one blob, attach it across utterances for the toggle.
            if utterances.allSatisfy({ $0.intendedText == nil }),
               let fullIntended = intended.map(\.text).joined(separator: " ").nilIfEmptyTrimmed {
                let words = fullIntended.split(whereSeparator: \.isWhitespace).map(String.init)
                if !words.isEmpty, !utterances.isEmpty {
                    let total = max(utterances.reduce(0) { $0 + max($1.endMs - $1.startMs, 1) }, 1)
                    var cursor = 0
                    for i in utterances.indices {
                        let share = Double(max(utterances[i].endMs - utterances[i].startMs, 1)) / Double(total)
                        var count = Int((share * Double(words.count)).rounded())
                        if i == utterances.count - 1 { count = words.count - cursor }
                        let end = min(cursor + max(count, 0), words.count)
                        utterances[i].intendedText = words[cursor..<end].joined(separator: " ")
                        cursor = end
                    }
                }
            }

            let stamp = capture.startedAt.formatted(date: .abbreviated, time: .shortened)
            var session = ConversationSession(
                title: "Meeting — \(stamp)",
                startedAt: capture.startedAt,
                endedAt: capture.endedAt,
                source: includeSystemAudio ? .mixed : .meeting,
                utterances: utterances
            )
            if let first = utterances.first, !first.text.isEmpty {
                session.title = String(first.text.prefix(56))
            }
            guard !utterances.isEmpty else {
                statusMessage = "Meeting ended — no speech detected"
                return
            }
            let speakerCount = Set(utterances.compactMap(\.speakerID)).count
            try store.saveSession(session)
            selectedMeetingID = session.id
            statusMessage = "Meeting saved · \(utterances.count) lines · \(max(speakerCount, 1)) speakers"
            reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
