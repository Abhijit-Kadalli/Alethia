import AppKit
import SwiftUI
import AlethiaCore
import AlethiaDictation
import AlethiaKnowledge
import AlethiaMeetings
import AlethiaSpeech

enum HubClipboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct HubView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HubShell(recorder: env.recorder, processor: env.processor, models: env.models)
    }
}

private struct HubShell: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var nav = HubNavigation.shared
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var models: ModelManager

    @State private var selectedDictationID: UUID?
    @State private var selectedSpeakerID: UUID?
    @State private var selectedDictionaryID: UUID?
    @State private var selectedSnippetID: UUID?
    @State private var dismissedStartupError = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 460)
        } detail: {
            VStack(spacing: 0) {
                banners
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(
            text: $nav.searchQuery,
            placement: .sidebar,
            prompt: "Search meetings, notes, dictations"
        )
        .onChange(of: nav.searchQuery) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nav.section = .meetings
            }
        }
    }

    private var sidebar: some View {
        List(selection: $nav.section) {
            ForEach(HubSection.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Alethia")
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch nav.section {
        case .meetings:
            MeetingsView(
                recorder: recorder,
                processor: processor,
                selectedDictationID: $selectedDictationID
            )
        case .dictations:
            DictationHistoryView(selection: $selectedDictationID)
        case .vocabulary:
            VocabularyView(
                selectedDictionaryID: $selectedDictionaryID,
                selectedSnippetID: $selectedSnippetID
            )
        case .speakers:
            SpeakersView(selection: $selectedSpeakerID)
        case .settings:
            settingsPaneList
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch nav.section {
        case .meetings:
            MeetingDetailView(recorder: recorder, processor: processor)
        case .dictations:
            DictationDetailView(dictationID: selectedDictationID)
        case .vocabulary:
            VocabularyDetailView(
                dictionaryID: selectedDictionaryID,
                snippetID: selectedSnippetID
            )
        case .speakers:
            SpeakerDetailView(selection: $selectedSpeakerID)
        case .settings:
            SettingsView()
        }
    }

    private var settingsPaneList: some View {
        List(selection: $nav.settingsPane) {
            ForEach(SettingsPane.allCases) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var banners: some View {
        if let error = env.startupError, !dismissedStartupError {
            HubBanner(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                message: error,
                onDismiss: { dismissedStartupError = true }
            )
        }
        if !models.recognizerInstalled(for: env.settings.speechModel) {
            HubBanner(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                message: "The speech model isn’t downloaded. Dictation and meeting transcription need it."
            ) {
                Button("Open Models") {
                    nav.select(section: .settings, pane: .models)
                }
                .controlSize(.small)
            }
        }
        if recorder.isRecording, !isShowingLiveMeetingView {
            HubBanner(
                symbol: "record.circle.fill",
                tint: .red,
                message: "Recording · \(TimeFormat.clock(ms: recorder.elapsedMs))"
            ) {
                Button("Stop") {
                    Task { await recorder.stop() }
                }
                .controlSize(.small)
                .tint(.red)
            }
        }
    }

    private var isShowingLiveMeetingView: Bool {
        guard nav.section == .meetings, recorder.isRecording else { return false }
        return nav.selectedMeetingID == nil || nav.selectedMeetingID == recorder.current?.id
    }
}

private struct HubBanner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let message: String
    var onDismiss: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    init(
        symbol: String,
        tint: Color,
        message: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.symbol = symbol
        self.tint = tint
        self.message = message
        self.onDismiss = onDismiss
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.55))
    }
}

extension HubBanner where Actions == EmptyView {
    init(symbol: String, tint: Color, message: String, onDismiss: (() -> Void)? = nil) {
        self.init(symbol: symbol, tint: tint, message: message, onDismiss: onDismiss) { EmptyView() }
    }
}
