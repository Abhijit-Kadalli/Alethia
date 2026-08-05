import AppKit
import SwiftUI
import AlethiaCore

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(model.recordingState == .stopped
                   ? "Start Meeting Recording"
                   : "Stop Meeting Recording") {
                model.toggleMeetingRecording()
            }
            .disabled(model.isTranscribingMeeting)

            if model.isTranscribingDictation {
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isDictating {
                Button("Finish Dictation") { model.endDictation() }
            } else {
                Button("Start Dictation") { model.beginDictation() }
                    .disabled(model.isTranscribingMeeting)
            }

            Toggle("Include system audio", isOn: $model.includeSystemAudio)
                .disabled(model.recordingState == .recording)

            Divider()

            Button("Open Hub") {
                NotificationCenter.default.post(name: .alethiaOpenHub, object: nil)
            }
            Button("Open Accessibility Settings") {
                model.permissions.openAccessibilitySettings()
            }
            Button("Quit Alethia") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(minWidth: 260)
    }
}

struct HubView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var renameDrafts: [UUID: String] = [:]
    @AppStorage("alethia.didOnboard") private var didOnboard = false
    @State private var showOnboarding = false
    @State private var meetingPendingDelete: ConversationSession?

    private let speakerColors: [Color] = [
        Color(red: 0.20, green: 0.45, blue: 0.55),
        Color(red: 0.55, green: 0.35, blue: 0.20),
        Color(red: 0.30, green: 0.50, blue: 0.30),
        Color(red: 0.50, green: 0.28, blue: 0.40)
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedMeetingID) {
                Section("Meetings") {
                    if model.sessions.isEmpty {
                        Text("No meetings yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title ?? "Meeting")
                                .font(.headline)
                                .lineLimit(2)
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(session.utterances.count) lines · \(displaySource(session.source))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .tag(session.id)
                        .contextMenu {
                            Button("Delete Meeting", role: .destructive) {
                                meetingPendingDelete = session
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                meetingPendingDelete = session
                            }
                        }
                    }
                }

                Section("Dictations") {
                    if model.dictations.isEmpty {
                        Text("Hold Fn to dictate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.dictations) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.verbatimText ?? event.text)
                                .font(.caption)
                                .lineLimit(3)
                            Text(event.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Search") {
                    TextField("Search transcripts & dictations", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: query) { _, value in
                            model.search(value)
                        }
                    ForEach(model.searchHits) { hit in
                        Button {
                            model.openSearchHit(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.title).font(.headline)
                                Text(hit.snippet).font(.caption).foregroundStyle(.secondary)
                                Text(hit.kind.rawValue.uppercased())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Speakers") {
                    ForEach(model.speakers) { speaker in
                        HStack {
                            TextField(
                                "Name",
                                text: Binding(
                                    get: { renameDrafts[speaker.id] ?? speaker.displayName },
                                    set: { renameDrafts[speaker.id] = $0 }
                                )
                            )
                            Button("Save") {
                                let name = renameDrafts[speaker.id] ?? speaker.displayName
                                model.renameSpeaker(speaker, to: name)
                            }
                            .disabled((renameDrafts[speaker.id] ?? speaker.displayName)
                                .trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if model.speakers.isEmpty {
                        Text("Speakers appear after meeting recordings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            NavigationStack {
                if let meeting = model.selectedMeeting {
                    MeetingDetailView(
                        session: meeting,
                        speakerColors: speakerColors,
                        onDelete: { meetingPendingDelete = meeting }
                    )
                } else if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet",
                        systemImage: "waveform.circle",
                        description: Text("Start meeting recording from the menu bar. Each meeting’s transcript appears here — toggle Verbatim / Clean in the detail view.")
                    )
                } else {
                    ContentUnavailableView(
                        "Select a meeting",
                        systemImage: "sidebar.left",
                        description: Text("Choose a meeting from the sidebar to view its transcript.")
                    )
                }
            }
        }
        .onAppear {
            model.reload()
            if !didOnboard {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: {
            didOnboard = true
        }) {
            OnboardingView(isPresented: $showOnboarding)
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(
                get: { meetingPendingDelete != nil },
                set: { if !$0 { meetingPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                if let id = meetingPendingDelete?.id {
                    model.deleteMeeting(id)
                }
                meetingPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                meetingPendingDelete = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func displaySource(_ source: CaptureSource) -> String {
        switch source {
        case .ambient, .meeting: return "mic"
        case .mixed: return "mic + system"
        case .dictation: return "dictation"
        }
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let session: ConversationSession
    let speakerColors: [Color]
    var onDelete: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.title ?? "Meeting")
                        .font(.title2.weight(.semibold))
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Transcript style", selection: $model.hubShowVerbatim) {
                        Text("Verbatim").tag(true)
                        Text("Clean").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)

                    Toggle("Per-word timings", isOn: $model.hubShowWordTimings)
                        .toggleStyle(.switch)
                        .frame(maxWidth: 280, alignment: .leading)

                    Text(model.hubShowVerbatim
                         ? "What was said (fillers & disfluencies kept)"
                         : "What was meant (cleaned / intended)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if model.hubShowWordTimings {
                        Text("Shows start time under each word when available (new meetings).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                if session.utterances.isEmpty {
                    Text("No transcript stored for this meeting.")
                        .foregroundStyle(.secondary)
                } else {
                    let speakers = uniqueSpeakers(session.utterances)
                    Text("\(speakers.count) speaker\(speakers.count == 1 ? "" : "s")")
                        .font(.headline)

                    ForEach(Array(session.utterances.enumerated()), id: \.element.id) { idx, u in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(u.speakerLabel)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(color(for: u, index: idx))
                                    Text(formatMs(u.startMs))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(width: 100, alignment: .leading)
                                Text(u.displayText(verbatim: model.hubShowVerbatim))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            if model.hubShowWordTimings {
                                if u.words.isEmpty {
                                    Text("No word timings for this line")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 112)
                                } else {
                                    WordTimingFlow(words: u.words)
                                        .padding(.leading, 112)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete Meeting", role: .destructive, action: onDelete)
            }
        }
    }

    private var metaLine: String {
        let start = session.startedAt.formatted(date: .abbreviated, time: .shortened)
        let end = session.endedAt?.formatted(date: .omitted, time: .shortened)
        let speakers = uniqueSpeakers(session.utterances).count
        if let end {
            return "\(start) – \(end) · \(session.utterances.count) lines · \(speakers) speakers"
        }
        return "\(start) · \(session.utterances.count) lines · \(speakers) speakers"
    }

    private func uniqueSpeakers(_ utterances: [Utterance]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in utterances {
            if seen.insert(u.speakerLabel).inserted {
                out.append(u.speakerLabel)
            }
        }
        return out
    }

    private func color(for utterance: Utterance, index: Int) -> Color {
        let speakers = uniqueSpeakers(session.utterances)
        let speakerIndex = speakers.firstIndex(of: utterance.speakerLabel) ?? index
        return speakerColors[speakerIndex % speakerColors.count]
    }

    private func formatMs(_ ms: Int) -> String {
        let total = max(ms, 0) / 1000
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct WordTimingFlow: View {
    let words: [TimedWord]

    var body: some View {
        FlexibleWordWrap(words: words)
    }
}

/// Simple wrapping layout for timed words without UIKit FlowLayout.
private struct FlexibleWordWrap: View {
    let words: [TimedWord]

    var body: some View {
        // Chunk into rows of ~8 words for readability.
        let rows = stride(from: 0, to: words.count, by: 8).map { start in
            Array(words[start..<min(start + 8, words.count)])
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row) { w in
                        VStack(spacing: 1) {
                            Text(w.word)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text(formatMs(w.startMs))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let total = max(ms, 0)
        let m = total / 60_000
        let s = (total % 60_000) / 1000
        let frac = (total % 1000) / 100
        if m > 0 {
            return String(format: "%d:%02d.%d", m, s, frac)
        }
        return String(format: "%d.%ds", s, frac)
    }
}

struct OnboardingView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Alethia")
                .font(.title.weight(.semibold))
            Text("Fully local meeting transcripts + speak-to-type. Audio and transcripts stay on your Mac.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Hold Fn — dictate into any app", systemImage: "keyboard")
                Label("Menu bar — start/stop meeting recording", systemImage: "record.circle")
                Label("Hub — each meeting’s verbatim transcript", systemImage: "list.bullet.rectangle")
                Label("Microphone — meetings & dictation", systemImage: "mic")
                Label("Accessibility — auto-paste dictated text", systemImage: "accessibility")
                Label("Screen Recording — optional system audio for meetings", systemImage: "rectangle.dashed.badge.record")
            }
            Text("Recording others may require consent. You are responsible for following local law and policy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Continue") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
    }
}
