import AppKit
import SwiftUI
import AlethiaCore
import AlethiaDictation
import AlethiaKnowledge
import AlethiaSpeech
import AlethiaText

/// Settings section of the Hub: a pane list on the left, forms on the right.
struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var nav = HubNavigation.shared

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $nav.settingsPane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            ScrollView {
                pane
                    .padding(24)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var pane: some View {
        switch nav.settingsPane {
        case .general: GeneralSettingsPane()
        case .dictation: DictationSettingsPane(dictation: env.dictation)
        case .meetings: MeetingSettingsPane()
        case .models: ModelSettingsPane(models: env.models)
        case .intelligence: IntelligenceSettingsPane()
        case .privacy: PrivacySettingsPane()
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Alethia at login", isOn: $env.settings.launchAtLogin)
                Text("Alethia runs in the menu bar and uses no CPU until you dictate or record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sounds") {
                Toggle("Play sounds when dictation starts and stops", isOn: $env.settings.dictation.playSounds)
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                LabeledContent("Speech", value: "FluidAudio · NVIDIA Parakeet TDT · Apache-2.0 / CC-BY")
                Link("Source code and licenses", destination: URL(string: "https://github.com/lewistowler/alethia")!)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictation

private struct DictationSettingsPane: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var dictation: DictationController

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Key", selection: $env.settings.dictation.hotkey) {
                    ForEach(DictationHotkey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Mode", selection: $env.settings.dictation.activation) {
                    ForEach(DictationActivation.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if !dictation.hotkeyActive {
                    HStack {
                        Label("Accessibility permission is needed for the hotkey.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            _ = env.permissions.accessibilityTrusted(prompt: true)
                            env.permissions.openAccessibilitySettings()
                        }
                    }
                }
            }
            Section("Cleanup") {
                Toggle("Remove fillers (um, uh, you know)", isOn: $env.settings.dictation.removeFillers)
                Toggle("Resolve self-corrections (\"Tuesday, no, Wednesday\")", isOn: $env.settings.dictation.resolveSelfCorrections)
                Toggle("Voice commands (\"new line\", \"period\", \"scratch that\")", isOn: $env.settings.dictation.applyVoiceCommands)
                Toggle("Smart formatting for numbers, dates, emails and URLs", isOn: $env.settings.dictation.smartFormatting)
                Toggle("Match the style of the app you're typing in", isOn: $env.settings.dictation.appAwareStyle)
            }
            Section("After inserting") {
                Toggle("Show a correction popover", isOn: $env.settings.dictation.showCorrectionPopover)
                if env.settings.dictation.showCorrectionPopover {
                    HStack {
                        Text("Keep it open for")
                        Slider(value: $env.settings.dictation.correctionPopoverSeconds, in: 2...10, step: 1)
                        Text("\(Int(env.settings.dictation.correctionPopoverSeconds)) s").monospacedDigit().frame(width: 32)
                    }
                    Text("Edits you make there teach the dictionary, so the same word comes out right next time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep dictation history", isOn: $env.settings.dictation.keepHistory)
            }
            Section("Language") {
                TextField("Language hint (e.g. en, de, fr — empty for auto)", text: $env.settings.dictation.language)
                Text(env.settings.speechModel == .parakeetV2English
                     ? "The English model ignores this hint. Choose the multilingual model under Models to dictate in other languages."
                     : "Leave empty to detect the language automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Meetings

private struct MeetingSettingsPane: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var templates: [NotesTemplate] = NotesTemplate.builtIn

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Capture other participants (system audio)", isOn: $env.settings.meetings.includeSystemAudio)
                if env.settings.meetings.includeSystemAudio, !env.permissions.screenRecordingGranted() {
                    HStack {
                        Label("Needs the Screen & System Audio Recording permission.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Allow") {
                            if !env.permissions.requestScreenRecording() { env.permissions.openScreenRecordingSettings() }
                        }
                    }
                }
                Toggle("Show a live transcript while recording", isOn: $env.settings.meetings.liveTranscript)
                Toggle("Keep audio recordings after processing", isOn: $env.settings.meetings.keepAudio)
            }
            Section("Detection") {
                Toggle("Offer to record when a call starts", isOn: $env.settings.meetings.detectMeetings)
                Text("Alethia watches for Zoom, Meet, Teams, Slack, FaceTime and others using the microphone. Nothing is recorded until you accept.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use Calendar for meeting titles and attendees", isOn: $env.settings.meetings.useCalendar)
                    .onChange(of: env.settings.meetings.useCalendar) { _, enabled in
                        guard enabled, env.calendar.authorizationState != .granted else { return }
                        Task {
                            if await env.calendar.requestAccess() != .granted {
                                env.settings.meetings.useCalendar = false
                                env.permissions.openCalendarSettings()
                            }
                        }
                    }
            }
            Section("Notes") {
                Picker("Default template", selection: $env.settings.meetings.defaultTemplateID) {
                    ForEach(templates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                if let template = templates.first(where: { $0.id == env.settings.meetings.defaultTemplateID }) {
                    Text(template.description).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { templates = (try? env.store.allTemplates()) ?? NotesTemplate.builtIn }
    }
}

// MARK: - Models

private struct ModelSettingsPane: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var models: ModelManager
    @State private var error: String?
    @State private var confirmDelete: ModelComponent?

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("Model", selection: $env.settings.speechModel) {
                    ForEach(SpeechModelVariant.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .disabled(models.activeDownloads > 0)
                Text("Parakeet TDT 0.6B v2 is the most accurate for English. v3 detects and transcribes 25 European languages. Both run on the Neural Engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Installed models") {
                ForEach(ModelComponent.allCases) { component in
                    HStack(alignment: .center) {
                        ModelRow(component: component, state: models.state(of: component))
                        modelActions(component)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if !models.allInstalled(for: env.settings.speechModel) && models.activeDownloads == 0 {
                    Button("Download everything for \(env.settings.speechModel.displayName)") {
                        download(ModelComponent.required(for: env.settings.speechModel))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Section("Storage") {
                LabeledContent("Location") {
                    HStack {
                        Text(models.modelsDirectory.path).font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([models.modelsDirectory]) }
                            .controlSize(.small)
                    }
                }
                Text("Models are shared with other FluidAudio-based apps on this Mac and can be deleted at any time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
        .confirmationDialog("Delete \(confirmDelete?.displayName ?? "model")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let component = confirmDelete {
                    try? models.delete(component)
                    Task { await env.speech.unload() }
                }
                confirmDelete = nil
            }
        }
    }

    @ViewBuilder
    private func modelActions(_ component: ModelComponent) -> some View {
        switch models.state(of: component) {
        case .installed:
            Text(ByteCountFormatter.string(fromByteCount: models.installedBytes(component), countStyle: .file))
                .font(.caption).foregroundStyle(.secondary)
            Button { confirmDelete = component } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        case .downloading:
            Button("Cancel") { models.cancelDownload(component) }.controlSize(.small)
        case .notInstalled, .failed:
            Button("Download") { download([component]) }.controlSize(.small)
        }
    }

    private func download(_ components: [ModelComponent]) {
        error = nil
        Task {
            for component in components where !models.state(of: component).isInstalled {
                do {
                    try await models.download(component)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            if models.recognizerInstalled(for: env.settings.speechModel) {
                try? await env.speech.prepare()
            }
        }
    }
}

// MARK: - AI

private struct IntelligenceSettingsPane: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Language model") {
                Picker("Provider", selection: $env.settings.languageModel.provider) {
                    ForEach(LanguageModelProviderKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Text(providerDescription).font(.caption).foregroundStyle(.secondary)
            }
            if env.settings.languageModel.provider == .openAICompatible {
                Section("Server") {
                    TextField("Base URL", text: $env.settings.languageModel.baseURL, prompt: Text("http://localhost:11434/v1"))
                    TextField("Model", text: $env.settings.languageModel.model, prompt: Text("qwen3:4b"))
                    SecureField("API key (optional for local servers)", text: $apiKey)
                        .onSubmit(saveKey)
                    HStack {
                        Button(testing ? "Testing…" : "Test connection") { test() }.disabled(testing)
                        if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Works with Ollama, LM Studio, llama.cpp server, OpenAI, OpenRouter, Groq, or anything speaking the OpenAI chat completions API. Local servers keep everything on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if env.settings.languageModel.provider == .appleIntelligence, !AppleIntelligenceProvider.isSupported {
                Section {
                    Label("Apple Intelligence needs macOS 26 or later on an Apple silicon Mac.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Use it for") {
                Toggle("Meeting notes (structured summary after each meeting)", isOn: $env.settings.languageModel.autoEnhanceNotes)
                Toggle("Polish dictation (grammar and flow, keeps your words)", isOn: $env.settings.languageModel.polishDictation)
                Text("Without a language model Alethia still cleans up dictation with rules and writes heuristic meeting notes from the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(env.settings.languageModel.provider == .none)
        }
        .formStyle(.grouped)
        .onAppear { apiKey = KeychainStore.get(account: env.settings.languageModel.apiKeyAccount) ?? "" }
        .onDisappear(perform: saveKey)
    }

    private var providerDescription: String {
        switch env.settings.languageModel.provider {
        case .none: return "Rule-based cleanup only. Fastest and fully private."
        case .appleIntelligence: return "Apple's on-device model. Private, no setup."
        case .openAICompatible: return "Point Alethia at a local model server or a cloud API."
        }
    }

    private func saveKey() {
        let account = env.settings.languageModel.apiKeyAccount
        if apiKey.isEmpty {
            KeychainStore.delete(account: account)
        } else {
            try? KeychainStore.set(apiKey, account: account)
        }
        env.reloadLanguageModelProvider()
    }

    private func test() {
        saveKey()
        testing = true
        testResult = nil
        let provider = AppEnvironment.makeProvider(env.settings.languageModel)
        Task {
            defer { testing = false }
            guard let provider else { testResult = "No provider configured."; return }
            if await provider.isAvailable() {
                do {
                    let reply = try await provider.complete(LanguageModelRequest(system: "Reply with the single word OK.", user: "Ping", maxTokens: 5, temperature: 0))
                    testResult = "Connected · \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))"
                } catch {
                    testResult = "Reachable, but the request failed: \(error.localizedDescription)"
                }
            } else {
                testResult = "Could not reach the server or model."
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacySettingsPane: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var stats: KnowledgeStore.Stats?
    @State private var recordingsBytes: Int64 = 0
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteRecordings = false

    var body: some View {
        Form {
            Section("How Alethia handles your data") {
                Text("Audio is processed on this Mac by open-source models. Transcripts, notes and dictation history are stored in a local SQLite database. Nothing is sent anywhere unless you connect a cloud language model under AI.")
                    .font(.callout)
            }
            Section("On this Mac") {
                if let stats {
                    LabeledContent("Meetings", value: "\(stats.meetingCount) · \(TimeFormat.duration(ms: stats.totalMeetingMs))")
                    LabeledContent("Dictations", value: "\(stats.dictationCount) · \(stats.dictatedWords) words")
                    LabeledContent("Speakers", value: "\(stats.speakerCount)")
                }
                LabeledContent("Recordings", value: ByteCountFormatter.string(fromByteCount: recordingsBytes, countStyle: .file))
                LabeledContent("Location") {
                    HStack {
                        Text(env.paths.root.path).font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([env.paths.root]) }.controlSize(.small)
                    }
                }
            }
            Section("Delete") {
                Button("Delete all audio recordings…") { confirmDeleteRecordings = true }
                Button("Delete all meetings, dictations and speakers…", role: .destructive) { confirmDeleteAll = true }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: env.storeGeneration) { _, _ in refresh() }
        .confirmationDialog("Delete all recordings?", isPresented: $confirmDeleteRecordings) {
            Button("Delete recordings", role: .destructive) { deleteRecordings() }
        } message: {
            Text("Transcripts and notes are kept. You won't be able to re-run transcription.")
        }
        .confirmationDialog("Delete everything?", isPresented: $confirmDeleteAll) {
            Button("Delete everything", role: .destructive) {
                try? env.deleteAllData()
                deleteRecordings()
            }
        } message: {
            Text("This removes every meeting, transcript, note, dictation and speaker profile. Your dictionary and settings are kept.")
        }
    }

    private func refresh() {
        stats = try? env.store.stats()
        recordingsBytes = env.paths.recordingsSizeBytes()
    }

    private func deleteRecordings() {
        let meetings = (try? env.store.listMeetings(limit: 10_000)) ?? []
        for var meeting in meetings where meeting.audioPath != nil {
            if let path = meeting.audioPath {
                try? FileManager.default.removeItem(at: env.paths.resolve(relativePath: path))
            }
            meeting.audioPath = nil
            try? env.store.updateMeetingMetadata(meeting)
        }
        if let items = try? FileManager.default.contentsOfDirectory(at: env.paths.recordings, includingPropertiesForKeys: nil) {
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        refresh()
    }
}
