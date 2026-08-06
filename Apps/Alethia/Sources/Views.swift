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
            Button("Open Microphone Settings") {
                model.permissions.openMicrophoneSettings()
            }
            Button("Open Accessibility Settings") {
                model.permissions.openAccessibilitySettings()
            }
            Text("Hold Fn (🌐) or Right ⌥ to dictate. After rebuilding the app, re-add Alethia in Accessibility.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit Alethia") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(minWidth: 260)
    }
}

struct HubView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @AppStorage("alethia.didOnboard") private var didOnboard = false
    @State private var showOnboarding = false
    @State private var meetingPendingDelete: ConversationSession?
    @State private var showSettings = false

    private let speakerColors: [Color] = [
        Color(red: 0.18, green: 0.42, blue: 0.52),
        Color(red: 0.52, green: 0.34, blue: 0.18),
        Color(red: 0.28, green: 0.48, blue: 0.30),
        Color(red: 0.48, green: 0.26, blue: 0.38),
        Color(red: 0.32, green: 0.36, blue: 0.55)
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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title ?? "Meeting")
                                .font(.headline)
                                .lineLimit(2)
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text("\(session.utterances.count) lines")
                                Text("·")
                                Text(displaySource(session.source))
                                if session.notesMarkdown != nil {
                                    Text("·")
                                    Image(systemName: "doc.text")
                                }
                                if session.audioPath != nil {
                                    Text("·")
                                    Image(systemName: "waveform")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
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
                                Text(hit.title).font(.subheadline.weight(.semibold))
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
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
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
                        description: Text("Start meeting recording from the menu bar. Transcripts, people, and notes appear here.")
                    )
                } else {
                    ContentUnavailableView(
                        "Select a meeting",
                        systemImage: "sidebar.left",
                        description: Text("Choose a meeting from the sidebar to view its transcript and notes.")
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
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

// MARK: - Meeting detail

struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let session: ConversationSession
    let speakerColors: [Color]
    var onDelete: () -> Void = {}

    @State private var labelDrafts: [UUID: String] = [:]
    @StateObject private var audio = MeetingAudioPlayer()

    private var people: [MeetingPerson] {
        MeetingPerson.unique(from: session.utterances)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if audio.hasAudio || session.audioPath != nil {
                    audioBar
                }
                peopleSection
                notesSection
                transcriptSection
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.generateNotes(for: session)
                } label: {
                    if model.isGeneratingNotes {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(
                            session.notesMarkdown == nil ? "Generate Notes" : "Regenerate Notes",
                            systemImage: "sparkles"
                        )
                    }
                }
                .disabled(model.isGeneratingNotes || session.utterances.isEmpty)
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .onAppear {
            for person in people {
                if labelDrafts[person.id] == nil {
                    labelDrafts[person.id] = person.label
                }
            }
            audio.load(url: model.store.resolveAudioURL(for: session))
        }
        .onChange(of: session.id) { _, _ in
            labelDrafts = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.label) })
            audio.load(url: model.store.resolveAudioURL(for: session))
        }
        .onDisappear {
            audio.pause()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.title ?? "Meeting")
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)
            Text(metaLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Picker("Transcript", selection: $model.hubShowVerbatim) {
                    Text("Verbatim").tag(true)
                    Text("Clean").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Toggle("Word timings", isOn: $model.hubShowWordTimings)
                    .toggleStyle(.checkbox)
            }

            Text(model.hubShowVerbatim
                 ? "What was said — fillers and disfluencies kept"
                 : "What was meant — cleaned / intended phrasing")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var audioBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    audio.toggle()
                } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!audio.hasAudio)
                .help(audio.hasAudio ? "Play / pause recording" : "No audio archived for this meeting")

                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(
                        value: Double(audio.currentMs),
                        total: Double(max(audio.durationMs, 1))
                    )
                    .progressViewStyle(.linear)
                    HStack {
                        Text(formatMs(audio.currentMs))
                        Spacer()
                        Text(formatMs(audio.durationMs))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                if audio.hasAudio {
                    Text("Click a timestamp to jump")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let err = audio.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if !audio.hasAudio {
                Text("No recording on disk for this meeting (only new recordings are archived).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People")
                .font(.title3.weight(.semibold))
            Text("Label Person 1 / Person 2 for this meeting. Over time, Alethia learns voice fingerprints and only suggests a name when confidence is at least 80%.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if people.isEmpty {
                Text("No speakers detected in this transcript.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(people.enumerated()), id: \.element.id) { idx, person in
                        personRow(person, color: speakerColors[idx % speakerColors.count])
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func personRow(_ person: MeetingPerson, color: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(color.opacity(0.9))
                .frame(width: 28, height: 28)
                .overlay {
                    Text(person.initials)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(
                        "Name",
                        text: Binding(
                            get: { labelDrafts[person.id] ?? person.label },
                            set: { labelDrafts[person.id] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                    Button("Save") {
                        let name = labelDrafts[person.id] ?? person.label
                        model.labelMeetingSpeaker(
                            sessionID: session.id,
                            speakerID: person.id,
                            name: name
                        )
                    }
                    .disabled(((labelDrafts[person.id] ?? person.label)
                        .trimmingCharacters(in: .whitespaces)).isEmpty)

                    if let suggestion = person.suggestion, let confidence = person.confidence {
                        Button {
                            model.acceptSpeakerSuggestion(
                                sessionID: session.id,
                                speakerID: person.id,
                                name: suggestion
                            )
                            labelDrafts[person.id] = suggestion
                        } label: {
                            Label(
                                "Maybe \(suggestion) · \(Int((confidence * 100).rounded()))%",
                                systemImage: "sparkle.magnifyingglass"
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(color)
                        .help("Accept identity suggestion (≥ 80% confidence)")
                    }
                }
                Text("\(person.lineCount) line\(person.lineCount == 1 ? "" : "s") in this meeting")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notes")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let generated = session.notesGeneratedAt {
                    Text("Updated \(generated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let err = model.notesError, model.selectedMeetingID == session.id {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let notes = session.notesMarkdown, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No notes yet")
                        .font(.headline)
                    Text(model.hasOpenRouterAPIKey
                          ? "Generate a summary with GPT-5.6 Luna via OpenRouter."
                          : "Add an OpenRouter API key in Settings, then generate notes with GPT-5.6 Luna.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        model.generateNotes(for: session)
                    } label: {
                        Label(
                            model.isGeneratingNotes ? "Generating…" : "Generate Notes",
                            systemImage: "sparkles"
                        )
                    }
                    .disabled(model.isGeneratingNotes || session.utterances.isEmpty || !model.hasOpenRouterAPIKey)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript")
                .font(.title3.weight(.semibold))

            if session.utterances.isEmpty {
                Text("No transcript stored for this meeting.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.utterances.enumerated()), id: \.element.id) { idx, u in
                        utteranceRow(u, index: idx)
                        if idx < session.utterances.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func utteranceRow(_ u: Utterance, index: Int) -> some View {
        let color = color(for: u, index: index)
        let isActive = audio.hasAudio
            && audio.currentMs >= u.startMs
            && audio.currentMs < max(u.endMs, u.startMs + 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                        Text(u.speakerLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(color)
                    }
                    Button {
                        audio.seek(toMs: u.startMs, andPlay: true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 9))
                            Text(formatMs(u.startMs))
                                .font(.caption2.monospacedDigit())
                        }
                        .foregroundStyle(audio.hasAudio ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!audio.hasAudio)
                    .help(audio.hasAudio ? "Jump to \(formatMs(u.startMs)) in the recording" : "No audio available")
                    if let suggestion = u.suggestedSpeakerLabel, let conf = u.matchConfidence {
                        Text("Maybe \(suggestion) · \(Int((conf * 100).rounded()))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 130, alignment: .leading)

                Text(u.displayText(verbatim: model.hubShowVerbatim))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if model.hubShowWordTimings {
                if u.words.isEmpty {
                    Text("No word timings for this line")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 142)
                } else {
                    WordTimingFlow(words: u.words) { ms in
                        audio.seek(toMs: ms, andPlay: true)
                    }
                    .padding(.leading, 142)
                    .opacity(audio.hasAudio ? 1 : 0.55)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? color.opacity(0.08) : .clear)
        )
    }

    private var metaLine: String {
        let start = session.startedAt.formatted(date: .abbreviated, time: .shortened)
        let end = session.endedAt?.formatted(date: .omitted, time: .shortened)
        let speakers = people.count
        if let end {
            return "\(start) – \(end) · \(session.utterances.count) lines · \(speakers) people"
        }
        return "\(start) · \(session.utterances.count) lines · \(speakers) people"
    }

    private func color(for utterance: Utterance, index: Int) -> Color {
        let labels = people.map(\.label)
        let speakerIndex = labels.firstIndex(of: utterance.speakerLabel) ?? index
        return speakerColors[speakerIndex % speakerColors.count]
    }

    private func formatMs(_ ms: Int) -> String {
        let total = max(ms, 0) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MeetingPerson: Identifiable, Hashable {
    let id: UUID
    let label: String
    let suggestion: String?
    let confidence: Float?
    let lineCount: Int

    var initials: String {
        let parts = label.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(label.prefix(2)).uppercased()
    }

    static func unique(from utterances: [Utterance]) -> [MeetingPerson] {
        var order: [UUID] = []
        var map: [UUID: (label: String, suggestion: String?, confidence: Float?, count: Int)] = [:]
        for u in utterances {
            guard let sid = u.speakerID else { continue }
            if map[sid] == nil {
                order.append(sid)
                map[sid] = (u.speakerLabel, u.suggestedSpeakerLabel, u.matchConfidence, 1)
            } else {
                map[sid]!.count += 1
                if map[sid]!.suggestion == nil {
                    map[sid]!.suggestion = u.suggestedSpeakerLabel
                    map[sid]!.confidence = u.matchConfidence
                }
            }
        }
        // Fallback for utterances without speakerID: group by label.
        if order.isEmpty {
            var byLabel: [String: (UUID, Int, String?, Float?)] = [:]
            var labelOrder: [String] = []
            for u in utterances {
                if byLabel[u.speakerLabel] == nil {
                    labelOrder.append(u.speakerLabel)
                    byLabel[u.speakerLabel] = (u.speakerID ?? UUID(), 1, u.suggestedSpeakerLabel, u.matchConfidence)
                } else {
                    byLabel[u.speakerLabel]!.1 += 1
                }
            }
            return labelOrder.compactMap { label in
                guard let row = byLabel[label] else { return nil }
                return MeetingPerson(
                    id: row.0,
                    label: label,
                    suggestion: row.2,
                    confidence: row.3,
                    lineCount: row.1
                )
            }
        }
        return order.compactMap { id in
            guard let row = map[id] else { return nil }
            return MeetingPerson(
                id: id,
                label: row.label,
                suggestion: row.suggestion,
                confidence: row.confidence,
                lineCount: row.count
            )
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyDraft = ""
    @State private var showKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2.weight(.semibold))

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("OpenRouter")
                        .font(.headline)
                    Text("Used only for optional meeting notes. Audio and transcripts stay on your Mac; the transcript text is sent to OpenRouter when you generate notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Group {
                            if showKey {
                                TextField("sk-or-…", text: $apiKeyDraft)
                            } else {
                                SecureField("sk-or-…", text: $apiKeyDraft)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button(showKey ? "Hide" : "Show") {
                            showKey.toggle()
                        }
                    }

                    Text("Model: GPT-5.6 Luna (`openai/gpt-5.6-luna`)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack {
                        Button("Save Key") {
                            model.openRouterAPIKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && model.openRouterAPIKey.isEmpty)

                        if model.hasOpenRouterAPIKey {
                            Button("Remove Key", role: .destructive) {
                                apiKeyDraft = ""
                                model.openRouterAPIKey = ""
                            }
                        }
                        Spacer()
                        Button("Done") { dismiss() }
                    }
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("People")
                        .font(.headline)
                    Text("Meetings start with Person 1, Person 2, …. Label them in the meeting view. Voice fingerprints update in the background; Alethia only shows “Maybe …” when confidence is ≥ 80%.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(model.speakers.filter(\.isUserLabeled).count) labeled · \(model.speakers.count) enrolled")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 520, height: 380)
        .onAppear {
            apiKeyDraft = model.openRouterAPIKey
        }
    }
}

// MARK: - Word timings

struct WordTimingFlow: View {
    let words: [TimedWord]
    var onSeek: ((Int) -> Void)?

    var body: some View {
        FlexibleWordWrap(words: words, onSeek: onSeek)
    }
}

private struct FlexibleWordWrap: View {
    let words: [TimedWord]
    var onSeek: ((Int) -> Void)?

    var body: some View {
        let rows = stride(from: 0, to: words.count, by: 8).map { start in
            Array(words[start..<min(start + 8, words.count)])
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row) { w in
                        Button {
                            onSeek?(w.startMs)
                        } label: {
                            VStack(spacing: 1) {
                                Text(w.word)
                                    .font(.caption.monospaced())
                                Text(formatMs(w.startMs))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(onSeek == nil)
                        .help("Jump to \(formatMs(w.startMs))")
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
            Text("Local meeting transcripts and speak-to-type. Label people as you go; optional OpenRouter notes stay under your control.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Hold Fn — dictate into any app", systemImage: "mic.fill")
                Label("Menu bar — start/stop meeting recording", systemImage: "record.circle")
                Label("Hub — Person 1 / Person 2, labels, and notes", systemImage: "person.2")
                Label("Microphone — meetings & dictation", systemImage: "waveform")
                Label("Accessibility — auto-paste dictated text", systemImage: "accessibility")
                Label("Screen Recording — optional system audio", systemImage: "rectangle.dashed.badge.record")
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
        .frame(width: 500)
    }
}
