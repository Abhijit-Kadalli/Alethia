import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications
import AlethiaAudio
import AlethiaCore
import AlethiaDictation
import AlethiaKnowledge
import AlethiaMeetings
import AlethiaSpeech
import AlethiaText

/// Composition root. One instance for the process; views reach it through the environment.
@MainActor
final class AppEnvironment: ObservableObject {
    let paths: AppPaths
    let settingsStore: SettingsStore
    let store: KnowledgeStore
    let permissions = PermissionGate()
    let models: ModelManager
    let calendar: CalendarService
    let detector = MeetingDetector()
    let processor: MeetingProcessor
    let recorder: MeetingRecorder
    let dictation: DictationController
    let speech: SpeechEngine

    /// Live copy of settings for SwiftUI bindings; writes go straight to `settingsStore`.
    @Published var settings: AppSettings {
        didSet {
            settingsStore.save(settings)
            settingsDidChange(from: oldValue)
        }
    }
    @Published private(set) var detectedCall: MeetingDetector.Detection?
    @Published private(set) var startupError: String?
    /// True when the on-disk store could not be opened; this session is not persisted.
    @Published private(set) var storeIsEphemeral = false
    /// Bumps whenever the knowledge store changes so list views refetch.
    @Published private(set) var storeGeneration = 0
    @Published private(set) var lastStoreChanges: Set<KnowledgeStore.Change> = []

    private let log = Log("App")
    private var changesTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(paths: AppPaths = .default) {
        self.paths = paths
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore
        let loaded = settingsStore.load()
        self.settings = loaded

        let store: KnowledgeStore
        var startupMessage: String?
        do {
            try paths.ensureDirectories()
            store = try KnowledgeStore(paths: paths)
        } catch {
            // A broken database must not take the whole app down; fall back to memory and surface it.
            guard let memory = try? KnowledgeStore.inMemory() else {
                fatalError("SQLite unavailable: \(error)")
            }
            store = memory
            startupMessage = "Could not open the local database. This session will not be saved. \(error.localizedDescription)"
        }
        store.startObservingChanges()
        self.store = store
        storeIsEphemeral = startupMessage != nil

        let models = ModelManager()
        self.models = models
        let speech = SpeechEngine(variant: loaded.speechModel, languageHint: loaded.dictation.language)
        self.speech = speech
        let calendar = CalendarService()
        self.calendar = calendar
        let processor = MeetingProcessor(store: store, speech: speech, settings: settingsStore, paths: paths)
        self.processor = processor
        recorder = MeetingRecorder(store: store, speech: speech, processor: processor, settings: settingsStore, paths: paths, calendar: calendar)
        dictation = DictationController(store: store, speech: speech, settings: settingsStore)
        startupError = startupMessage
        dictation.beginBlockedReason = { [weak recorder] in
            guard let recorder, recorder.phase != .idle else { return nil }
            return "Stop the meeting recording before dictating."
        }
        recorder.beginBlockedReason = { [weak dictation] in
            guard let dictation, dictation.state != .idle else { return nil }
            return "Stop dictation before recording a meeting."
        }

        let provider = Self.makeProvider(loaded.languageModel)
        processor.setNotesProducer(NotesBridge(provider: provider, enabled: loaded.languageModel.autoEnhanceNotes))
        dictation.polisher = provider.map { DictationPolisher(provider: $0) }

        changesTask = Task { [weak self] in
            guard let self else { return }
            for await changes in store.changes {
                self.lastStoreChanges = changes
                self.storeGeneration &+= 1
            }
        }
        detector.onMeetingDetected = { [weak self] detection in
            self?.handleDetectedCall(detection)
        }
        detector.onMeetingProbablyEnded = { [weak self] in
            self?.detectedCall = nil
        }
        recorder.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.detector.setRecording(self.recorder.isRecording)
                if case .recording = phase { self.detectedCall = nil }
            }
            .store(in: &cancellables)
    }

    // MARK: Startup

    /// Called once the UI is up. Safe to call again (idempotent).
    func start() {
        guard settings.didCompleteOnboarding else { return }
        models.refresh()
        applyHotkeyState()
        if settings.meetings.detectMeetings {
            detector.start()
        }
        processor.recoverInterrupted()
        if models.recognizerInstalled(for: settings.speechModel) {
            Task {
                do { try await speech.prepare() } catch { log.warning("warm-up failed: \(error.localizedDescription)") }
            }
        }
        requestNotificationPermission()
    }

    func completeOnboarding() {
        settings.didCompleteOnboarding = true
        start()
    }

    private func applyHotkeyState() {
        guard permissions.accessibilityTrusted(prompt: false) else {
            dictation.deactivateHotkey()
            return
        }
        do {
            try dictation.activateHotkey()
        } catch {
            log.warning("hotkey unavailable: \(error.localizedDescription)")
        }
    }

    /// Re-check permissions (called when the app becomes active or a settings pane appears).
    func refreshPermissions() {
        if settings.didCompleteOnboarding, !dictation.hotkeyActive {
            applyHotkeyState()
        }
    }

    /// Rebuild the LLM provider (after the API key or endpoint changed).
    func reloadLanguageModelProvider() {
        let provider = Self.makeProvider(settings.languageModel)
        processor.setNotesProducer(NotesBridge(provider: provider, enabled: settings.languageModel.autoEnhanceNotes))
        dictation.polisher = provider.map { DictationPolisher(provider: $0) }
    }

    private func settingsDidChange(from old: AppSettings) {
        dictation.settingsDidChange()
        if old.languageModel != settings.languageModel {
            reloadLanguageModelProvider()
        }
        if old.speechModel != settings.speechModel || old.dictation.language != settings.dictation.language {
            Task { await swapSpeechEngine() }
        }
        if old.meetings.detectMeetings != settings.meetings.detectMeetings {
            settings.meetings.detectMeetings ? detector.start() : detector.stop()
        }
        if old.launchAtLogin != settings.launchAtLogin {
            setLaunchAtLogin(settings.launchAtLogin)
        }
    }

    private func swapSpeechEngine() async {
        guard !recorder.isRecording, dictation.state == .idle else { return }
        await speech.configure(variant: settings.speechModel, languageHint: settings.dictation.language)
        if models.recognizerInstalled(for: settings.speechModel) {
            try? await speech.prepare()
        }
    }

    // MARK: Language model

    static func makeProvider(_ config: LanguageModelSettings) -> (any LanguageModelProvider)? {
        switch config.provider {
        case .none:
            return nil
        case .openAICompatible:
            guard let url = URL(string: config.baseURL) else { return nil }
            return OpenAICompatibleProvider(baseURL: url, apiKey: KeychainStore.get(account: config.apiKeyAccount), model: config.model)
        case .appleIntelligence:
            return AppleIntelligenceProvider.make()
        }
    }

    // MARK: Meeting detection

    private func handleDetectedCall(_ detection: MeetingDetector.Detection) {
        guard !recorder.isRecording else { return }
        detectedCall = detection
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "\(detection.appName ?? "A call") is using the microphone. Record notes?"
        content.categoryIdentifier = NotificationCategory.meetingDetected
        content.sound = nil
        let request = UNNotificationRequest(identifier: "meeting-detected", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func startDetectedMeeting() {
        let app = detectedCall?.appName
        detectedCall = nil
        Task {
            do {
                try await recorder.start(suggestedApp: app)
            } catch {
                log.error("start meeting failed: \(error.localizedDescription)")
            }
        }
    }

    func dismissDetectedCall() {
        detectedCall = nil
        detector.dismissActiveDetection()
    }

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: NotificationAction.startRecording, title: "Start recording", options: [.foreground])
        let category = UNNotificationCategory(identifier: NotificationCategory.meetingDetected, actions: [start], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Login item

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.warning("launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: Data

    func deleteAllData() throws {
        try store.deleteAllDictations()
        for meeting in try store.listMeetings(limit: 10_000) {
            try store.deleteMeeting(id: meeting.id)
        }
        for speaker in try store.speakers() {
            try store.deleteSpeaker(id: speaker.id)
        }
        try? store.vacuum()
    }

    func openHub() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum NotificationCategory {
    static let meetingDetected = "meeting-detected"
}

enum NotificationAction {
    static let startRecording = "start-recording"
}

/// Adapts `NotesGenerator` to the meetings module's protocol.
struct NotesBridge: MeetingNotesProducing {
    let provider: (any LanguageModelProvider)?
    let enabled: Bool

    func produceNotes(for meeting: Meeting, template: NotesTemplate) async -> ProducedNotes {
        let generator = NotesGenerator(provider: enabled ? provider : nil)
        let notes = await generator.generate(meeting: meeting, template: template)
        return ProducedNotes(markdown: notes.markdown, summary: notes.summary, suggestedTitle: notes.suggestedTitle, producedBy: notes.producedBy)
    }
}
