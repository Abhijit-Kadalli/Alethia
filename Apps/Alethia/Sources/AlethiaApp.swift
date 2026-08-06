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
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appModel)
                .background(OpenWindowRegistrar())
        } label: {
            Image(nsImage: appModel.menuBarNSImage)
                .renderingMode(.template)
                .accessibilityLabel(appModel.menuBarAccessibilityLabel)
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
    private let permissions = PermissionGate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenHub),
            name: .alethiaOpenHub,
            object: nil
        )
        // A menu-bar-only app may not be active early enough for macOS to put its
        // TCC sheet in front. Present an explicit foreground explanation first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.promptForMicrophoneAccess()
        }
    }

    @MainActor
    private func promptForMicrophoneAccess() {
        switch permissions.microphoneStatus() {
        case .granted:
            return
        case .notDetermined:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Allow Microphone Access"
            alert.informativeText = "Alethia needs microphone access for meeting recording and dictation. Audio is processed locally on this Mac. Click Continue, then Allow in the macOS permission dialog."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else {
                Self.restoreAccessoryPolicyIfNeeded()
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await self.permissions.requestMicrophone()
                if status == .denied {
                    self.showMicrophoneSettingsAlert()
                }
                Self.restoreAccessoryPolicyIfNeeded()
            }
        case .denied:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            showMicrophoneSettingsAlert()
            Self.restoreAccessoryPolicyIfNeeded()
        }
    }

    @MainActor
    private func showMicrophoneSettingsAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Microphone Access Is Off"
        alert.informativeText = "macOS has already recorded a denial for Alethia and will not show the Allow dialog again. Enable Alethia in Privacy & Security → Microphone."
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permissions.openMicrophoneSettings()
        }
    }

    @MainActor
    private static func restoreAccessoryPolicyIfNeeded() {
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.title == "Alethia" }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
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
    @Published var recordingState: RecordingState = .stopped {
        didSet { syncMenuBarAnimation() }
    }
    @Published var sessions: [ConversationSession] = []
    @Published var dictations: [DictationEvent] = []
    @Published var selectedMeetingID: UUID?
    @Published var speakers: [SpeakerProfile] = []
    @Published var searchHits: [KnowledgeHit] = []
    @Published var statusMessage: String = "Ready"
    @Published var isDictating = false {
        didSet { syncMenuBarAnimation() }
    }
    @Published var isTranscribingDictation = false {
        didSet { syncMenuBarAnimation() }
    }
    @Published var includeSystemAudio = true
    @Published var isTranscribingMeeting = false {
        didSet { syncMenuBarAnimation() }
    }
    /// Hub transcript display: verbatim (what was said) vs intended (cleaned).
    @Published var hubShowVerbatim = true
    /// Hub: show per-word timestamps under each utterance.
    @Published var hubShowWordTimings = false
    @Published var isGeneratingNotes = false {
        didSet { syncMenuBarAnimation() }
    }
    @Published var notesError: String?
    /// Animation frame for the custom menu-bar mark (idle is static).
    @Published var menuBarFrame: Int = 0

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

    private var menuBarAnimationTimer: Timer?

    var menuBarIconState: AlethiaMenuBarIconState {
        if isTranscribingDictation || isTranscribingMeeting || isGeneratingNotes {
            return .processing
        }
        if isDictating { return .dictating }
        switch recordingState {
        case .recording: return .meetingRecording
        case .stopped: return .idle
        }
    }

    var menuBarNSImage: NSImage {
        AlethiaMenuBarIcon.image(state: menuBarIconState, frame: menuBarFrame)
    }

    var menuBarAccessibilityLabel: String {
        switch menuBarIconState {
        case .idle: return "Alethia"
        case .dictating: return "Alethia — dictating"
        case .meetingRecording: return "Alethia — recording meeting"
        case .processing: return "Alethia — processing"
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
            dictation.willPaste = { [weak self] in
                self?.overlay.hide()
            }
            reload()
            syncMenuBarAnimation()
            Task { await self.bootstrapPermissionsAndASR() }
        } catch {
            fatalError("Failed to start Alethia: \(error)")
        }
    }

    /// Keep the status-item mark animating while dictating / recording / processing.
    func syncMenuBarAnimation() {
        let shouldAnimate: Bool = {
            switch menuBarIconState {
            case .idle: return false
            case .dictating, .meetingRecording, .processing: return true
            }
        }()
        if shouldAnimate {
            guard menuBarAnimationTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 8.0, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.menuBarFrame = (self.menuBarFrame + 1) % 120
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            menuBarAnimationTimer = timer
        } else {
            menuBarAnimationTimer?.invalidate()
            menuBarAnimationTimer = nil
            menuBarFrame = 0
        }
    }

    private func routePCM(_ samples: [Float]) {
        guard isDictating || dictation.isDictating else { return }
        dictation.appendPCM(samples)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
        overlay.updateLevel(rms)
    }

    func requestMicrophoneAccess() {
        switch permissions.microphoneStatus() {
        case .granted:
            statusMessage = "Microphone access is on"
        case .notDetermined:
            Task {
                let status = await permissions.requestMicrophone()
                statusMessage = status == .granted
                    ? "Microphone access is on"
                    : "Microphone access denied — open Microphone Settings to enable Alethia"
                await refreshStatus()
            }
        case .denied:
            permissions.openMicrophoneSettings()
            statusMessage = "Enable Alethia in Privacy & Security → Microphone, then reopen it"
        }
    }

    private func bootstrapPermissionsAndASR() async {
        statusMessage = permissions.microphoneStatus() == .denied
            ? "Microphone access is off — open Microphone Settings to enable Alethia"
            : "Checking microphone access…"

        if CrisperSidecarLauncher.hasBundledRuntime() {
            statusMessage = permissions.microphoneStatus() == .denied
                ? "Microphone access is off — open Microphone Settings to enable Alethia"
                : "Preparing on-device speech models… first launch downloads about 550 MB"
        } else if permissions.microphoneStatus() != .denied {
            statusMessage = "Starting local speech engine…"
        }
        let ready = await CrisperSidecarLauncher.ensureRunning()
        if !ready {
            if permissions.microphoneStatus() == .denied {
                statusMessage = "Microphone access is off — open Microphone Settings to enable Alethia"
            } else {
                statusMessage = CrisperSidecarLauncher.hasBundledRuntime()
                    ? "Speech model setup failed. Check your internet connection, then reopen Alethia."
                    : "ASR offline — run ./Scripts/setup-crisperwhisper.sh"
            }
            return
        }
        await refreshStatus()
    }

    private func refreshStatus() async {
        let asrOK = await CrisperWhisperRecognizer.isHealthy()
        let axOK = permissions.accessibilityTrusted(prompt: false)
        let microphoneStatus = permissions.microphoneStatus()
        var parts: [String] = []
        let offlineMessage = CrisperSidecarLauncher.hasBundledRuntime()
            ? "ASR: preparing models"
            : "ASR: offline — run ./Scripts/setup-crisperwhisper.sh"
        parts.append(asrOK ? "ASR: CrisperWhisper" : offlineMessage)
        parts.append(microphoneStatus == .granted ? "Mic: on" : "Mic: off — open Microphone Settings")
        if axOK {
            parts.append("AX: on · hold Fn or Right ⌥ to dictate")
            hotkey.refreshEventTap()
        } else {
            parts.append(PermissionGate.accessibilityRepairHint)
        }
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
                    statusMessage = CrisperSidecarLauncher.hasBundledRuntime()
                        ? "Preparing speech models…"
                        : "Starting ASR…"
                    let up = await CrisperSidecarLauncher.ensureRunning()
                    guard up else {
                        statusMessage = CrisperSidecarLauncher.hasBundledRuntime()
                            ? "Speech model setup failed. Check your internet connection and retry."
                            : "ASR offline — run ./Scripts/run-app.sh"
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
                    if permissions.accessibilityTrusted(prompt: false) {
                        statusMessage = "Copied (couldn’t auto-paste into the target app) — press ⌘V: “\(event.text.prefix(48))”"
                    } else {
                        statusMessage = "Copied — \(PermissionGate.accessibilityRepairHint)"
                        _ = permissions.accessibilityTrusted(prompt: true)
                    }
                } else {
                    let via = dictation.lastPasteMethod.map { " via \($0)" } ?? ""
                    statusMessage = "Pasted\(via): \(event.text.prefix(64))"
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

    func deleteMeeting(_ id: UUID) {
        do {
            try store.deleteSession(id: id)
            if selectedMeetingID == id { selectedMeetingID = nil }
            reload()
            statusMessage = "Meeting deleted"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func openSearchHit(_ hit: KnowledgeHit) {
        switch hit.kind {
        case .utterance:
            if let sid = try? store.sessionID(forUtteranceID: hit.id) {
                selectedMeetingID = sid
            }
        case .session:
            selectedMeetingID = hit.id
        case .dictation:
            break
        }
    }

    func renameSpeaker(_ speaker: SpeakerProfile, to name: String) {
        do {
            try gallery.rename(id: speaker.id, to: name)
            reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func labelMeetingSpeaker(sessionID: UUID, speakerID: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.relabelSpeaker(sessionID: sessionID, speakerID: speakerID, to: trimmed)
            try gallery.reload()
            reload()
            statusMessage = "Labeled as \(trimmed)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func acceptSpeakerSuggestion(sessionID: UUID, speakerID: UUID, name: String) {
        labelMeetingSpeaker(sessionID: sessionID, speakerID: speakerID, name: name)
    }

    var openRouterAPIKey: String {
        get { KeychainStore.get(account: KeychainStore.openRouterAPIKeyAccount) ?? "" }
        set {
            do {
                try KeychainStore.set(newValue, account: KeychainStore.openRouterAPIKeyAccount)
                objectWillChange.send()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    var hasOpenRouterAPIKey: Bool {
        !(KeychainStore.get(account: KeychainStore.openRouterAPIKeyAccount) ?? "").isEmpty
    }

    func generateNotes(for session: ConversationSession) {
        Task {
            await generateNotesAsync(for: session)
        }
    }

    private func generateNotesAsync(for session: ConversationSession) async {
        notesError = nil
        let key = openRouterAPIKey
        guard !key.isEmpty else {
            notesError = "Add an OpenRouter API key in Settings to generate notes."
            statusMessage = notesError ?? ""
            return
        }
        isGeneratingNotes = true
        statusMessage = "Generating notes…"
        defer { isGeneratingNotes = false }
        do {
            let client = OpenRouterNotesClient(apiKey: key)
            let markdown = try await client.generateNotes(
                title: session.title,
                startedAt: session.startedAt,
                utterances: session.utterances,
                verbatim: hubShowVerbatim
            )
            try store.updateSessionNotes(sessionID: session.id, markdown: markdown)
            reload()
            statusMessage = "Notes ready"
        } catch {
            notesError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    private func finalizeMeeting(_ capture: MeetingCapture) async {
        do {
            let durationSec = Double(capture.pcm.count) / max(capture.sampleRate, 1)
            statusMessage = String(format: "Transcribing %.0fs…", durationSec)

            // One ASR pass only (verbatim + word timings). A second parallel pass
            // contended for MPS and roughly doubled wall time.
            let transcripts = try await asr.transcribe(
                pcm: capture.pcm,
                sampleRate: capture.sampleRate,
                mode: .verbatim,
                wordTimestamps: true
            )
            let allWords = transcripts.flatMap(\.words)

            let diarized = try diarizer.diarize(
                pcm: capture.pcm,
                sampleRate: capture.sampleRate,
                transcripts: transcripts.map { ($0.startMs, $0.endMs, $0.text) },
                intendedTranscripts: []
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
                    words: words,
                    matchConfidence: d.matchConfidence,
                    suggestedSpeakerLabel: d.suggestedSpeakerLabel
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
                for i in utterances.indices {
                    utterances[i].words = allWords.filter {
                        $0.startMs >= utterances[i].startMs
                            && $0.startMs < max(utterances[i].endMs, utterances[i].startMs + 1)
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

            // Archive WAV so Hub timestamps can jump into the recording.
            let audioRel = store.relativeRecordingPath(for: session.id)
            let audioURL = store.recordingURL(for: session.id)
            do {
                try PCMWAVEncoder.write(
                    pcm: capture.pcm,
                    sampleRate: Int(capture.sampleRate),
                    to: audioURL
                )
                session.audioPath = audioRel
            } catch {
                // Meeting transcript still saves; playback just won't be available.
                statusMessage = "Meeting saved without audio archive: \(error.localizedDescription)"
            }

            let speakerCount = Set(utterances.compactMap(\.speakerID)).count
            try store.saveSession(session)
            selectedMeetingID = session.id
            if session.audioPath != nil {
                statusMessage = "Meeting saved · \(utterances.count) lines · \(max(speakerCount, 1)) speakers · audio ready"
            } else if statusMessage.hasPrefix("Meeting saved without") {
                // keep audio error
            } else {
                statusMessage = "Meeting saved · \(utterances.count) lines · \(max(speakerCount, 1)) speakers"
            }
            reload()

            // Fill Clean/intended transcript in the background (no word timestamps).
            let sessionID = session.id
            let pcm = capture.pcm
            let sampleRate = capture.sampleRate
            Task { await self.fillIntendedTranscript(sessionID: sessionID, pcm: pcm, sampleRate: sampleRate) }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Second, lighter ASR pass for the Hub Clean toggle — does not block meeting save.
    private func fillIntendedTranscript(sessionID: UUID, pcm: [Float], sampleRate: Double) async {
        do {
            let intended = try await asr.transcribe(
                pcm: pcm,
                sampleRate: sampleRate,
                mode: .intended,
                wordTimestamps: false
            )
            guard let fullIntended = intended.map(\.text).joined(separator: " ").nilIfEmptyTrimmed else { return }
            guard var session = try store.session(id: sessionID), !session.utterances.isEmpty else { return }

            let words = fullIntended.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return }

            // Prefer time-overlap segments when intended ASR returned timed phrases.
            let timed = intended.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if timed.count > 1 {
                for i in session.utterances.indices {
                    let u = session.utterances[i]
                    let parts = timed.compactMap { seg -> String? in
                        let lo = max(u.startMs, seg.startMs)
                        let hi = min(u.endMs, seg.endMs)
                        return hi > lo ? seg.text : nil
                    }
                    let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty {
                        session.utterances[i].intendedText = joined
                    }
                }
            } else {
                let total = max(session.utterances.reduce(0) { $0 + max($1.endMs - $1.startMs, 1) }, 1)
                var cursor = 0
                for i in session.utterances.indices {
                    let share = Double(max(session.utterances[i].endMs - session.utterances[i].startMs, 1)) / Double(total)
                    var count = Int((share * Double(words.count)).rounded())
                    if i == session.utterances.count - 1 { count = words.count - cursor }
                    let end = min(cursor + max(count, 0), words.count)
                    session.utterances[i].intendedText = words[cursor..<end].joined(separator: " ")
                    cursor = end
                }
            }

            try store.saveSession(session)
            if selectedMeetingID == sessionID {
                reload()
            }
        } catch {
            // Meeting already saved; Clean toggle can fall back to verbatim.
        }
    }
}

private extension String {
    var nilIfEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
