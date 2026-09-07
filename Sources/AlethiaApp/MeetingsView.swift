import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AlethiaCore
import AlethiaDictation
import AlethiaKnowledge
import AlethiaMeetings
import AlethiaText

struct MeetingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var nav = HubNavigation.shared
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var dictation: DictationController
    @Binding var selectedDictationID: UUID?

    @State private var meetings: [Meeting] = []
    @State private var hits: [SearchHit] = []
    @State private var pendingDeleteID: UUID?

    private var searchText: String {
        nav.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if searchText.isEmpty {
                meetingsList
            } else {
                searchList
            }
        }
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        guard let meeting = try? await recorder.start() else { return }
                        nav.selectedMeetingID = meeting.id
                    }
                } label: {
                    Label("Record meeting", systemImage: "record.circle")
                }
                .disabled(recorder.phase != .idle || dictation.state != .idle)
                .help(dictation.state != .idle ? "Stop dictation before recording" : "Record meeting")
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        ), titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) {
                if let id = pendingDeleteID {
                    deleteMeeting(id)
                }
                pendingDeleteID = nil
            }
        } message: {
            Text("The transcript, notes, and recording file will be removed.")
        }
        .task(id: env.storeGeneration) {
            meetings = (try? env.store.listMeetings(limit: 500)) ?? []
        }
        .task(id: searchTaskID) {
            if searchText.isEmpty {
                hits = []
            } else {
                hits = (try? env.store.search(searchText, limit: 50)) ?? []
            }
        }
    }

    private var searchTaskID: String { "\(searchText)\0\(env.storeGeneration)" }

    private var meetingsList: some View {
        Group {
            if meetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "person.2.wave.2",
                    description: Text("Record a meeting to capture notes and a transcript on this Mac.")
                )
            } else {
                List(selection: $nav.selectedMeetingID) {
                    ForEach(Self.dayGroups(meetings)) { group in
                        Section(group.title) {
                            ForEach(group.meetings) { meeting in
                                MeetingRow(meeting: meeting, recorder: recorder, processor: processor)
                                    .tag(meeting.id)
                                    .contextMenu {
                                        Button("Delete…", role: .destructive) {
                                            pendingDeleteID = meeting.id
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchList: some View {
        Group {
            if hits.isEmpty {
                ContentUnavailableView(
                    "No results",
                    systemImage: "magnifyingglass",
                    description: Text("No meetings, notes, or dictations match “\(searchText)”.")
                )
            } else {
                List {
                    ForEach(hits, id: \.self) { hit in
                        Button {
                            open(hit)
                        } label: {
                            SearchHitRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func open(_ hit: SearchHit) {
        switch hit.kind {
        case .dictation:
            selectedDictationID = hit.id
            nav.section = .dictations
        case .meetingTitle, .meetingNotes, .utterance:
            if let meetingID = hit.meetingID {
                nav.select(meetingID: meetingID)
            }
        }
    }

    private func deleteMeeting(_ id: UUID) {
        try? env.store.deleteMeeting(id: id)
        if nav.selectedMeetingID == id {
            nav.selectedMeetingID = nil
        }
    }

    private struct DayGroup: Identifiable {
        var id: Date
        var title: String
        var meetings: [Meeting]
    }

    private static func dayGroups(_ meetings: [Meeting]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for meeting in meetings {
            let day = calendar.startOfDay(for: meeting.startedAt)
            if let last = groups.last, last.id == day {
                groups[groups.count - 1].meetings.append(meeting)
            } else {
                groups.append(DayGroup(id: day, title: dayTitle(day, calendar: calendar), meetings: [meeting]))
            }
        }
        return groups
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var processor: MeetingProcessor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.hour().minute())
                Text("·")
                Text(durationText)
                statusBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var durationText: String {
        if recorder.current?.id == meeting.id {
            return TimeFormat.clock(ms: recorder.elapsedMs)
        }
        return TimeFormat.duration(ms: meeting.durationMs)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.status {
        case .recording:
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("Recording")
            }
        case .processing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(processor.progress[meeting.id]?.stage ?? "Processing")
            }
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
        case .ready:
            EmptyView()
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(hit.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(kindLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if !hit.snippet.isEmpty {
                Text(hit.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(hit.createdAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var kindLabel: String {
        switch hit.kind {
        case .meetingTitle: return "Title"
        case .meetingNotes: return "Notes"
        case .utterance: return "Transcript"
        case .dictation: return "Dictation"
        }
    }
}

struct MeetingDetailView: View {
    @ObservedObject private var nav = HubNavigation.shared
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var processor: MeetingProcessor

    var body: some View {
        Group {
            if recorder.isRecording, showsLive {
                LiveRecordingView(recorder: recorder)
            } else if nav.selectedMeetingID != nil {
                SavedMeetingDetail(processor: processor, meetingID: nav.selectedMeetingID)
            } else {
                ContentUnavailableView(
                    "Select a meeting",
                    systemImage: "person.2.wave.2",
                    description: Text("Choose a meeting from the list, or record a new one.")
                )
            }
        }
    }

    private var showsLive: Bool {
        nav.selectedMeetingID == nil || nav.selectedMeetingID == recorder.current?.id
    }
}

private struct LiveRecordingView: View {
    @ObservedObject private var nav = HubNavigation.shared
    @ObservedObject var recorder: MeetingRecorder
    @State private var title = ""
    @State private var notes = ""
    @State private var notesTask: Task<Void, Never>?
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("Recording")
                    .font(.headline)
                    .foregroundStyle(.red)
                Spacer()
            }
            Text(TimeFormat.clock(ms: recorder.elapsedMs))
                .font(.system(size: 48, weight: .medium, design: .rounded).monospacedDigit())

            VStack(alignment: .leading, spacing: 8) {
                labeledMeter("Microphone", value: recorder.level)
                labeledMeter("System", value: recorder.systemLevel)
            }

            if let warning = recorder.warning, !warning.isEmpty {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            TextField("Meeting title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onChange(of: title) { _, newValue in
                    guard newValue != recorder.current?.title else { return }
                    recorder.updateTitle(newValue)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("Your notes")
                    .font(.headline)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 160)
                    .onChange(of: notes) { _, newValue in
                        guard newValue != recorder.current?.userNotes else { return }
                        scheduleNotesSave(newValue)
                    }
            }

            liveTranscript
                .frame(maxHeight: .infinity)

            HStack {
                Button("Discard…") { confirmDiscard = true }
                Spacer()
                Button("Stop & process") {
                    notesTask?.cancel()
                    recorder.updateUserNotes(notes)
                    Task { await recorder.stop() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(recorder.phase == .stopping)
            }
        }
        .padding(20)
        .onAppear(perform: syncFromRecorder)
        .onChange(of: recorder.current?.id) { _, _ in
            syncFromRecorder()
        }
        .onDisappear {
            notesTask?.cancel()
            recorder.updateUserNotes(notes)
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard recording", role: .destructive) {
                let id = recorder.current?.id
                Task {
                    await recorder.discard()
                    if nav.selectedMeetingID == id {
                        nav.selectedMeetingID = nil
                    }
                }
            }
        } message: {
            Text("The audio and notes from this recording will be deleted.")
        }
        .navigationTitle(title.isEmpty ? "Recording" : title)
    }

    private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live transcript")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(recorder.liveTranscript.committed.enumerated()), id: \.offset) { _, segment in
                            HStack(alignment: .top, spacing: 10) {
                                Text(TimeFormat.clock(ms: segment.startMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                                Text(segment.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !recorder.liveTranscript.volatile.isEmpty {
                            HStack(alignment: .top, spacing: 10) {
                                Text(TimeFormat.clock(ms: recorder.liveTranscript.volatileStartMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                                Text(recorder.liveTranscript.volatile)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("live-bottom")
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: recorder.liveTranscript.committed.count) { _, _ in scroll(proxy) }
                .onChange(of: recorder.liveTranscript.volatile) { _, _ in scroll(proxy) }
            }
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func labeledMeter(_ title: String, value: Float) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(2, geo.size.width * CGFloat(min(max(value, 0), 1))))
                }
            }
            .frame(height: 8)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("live-bottom", anchor: .bottom)
    }

    private func syncFromRecorder() {
        title = recorder.current?.title ?? ""
        notes = recorder.current?.userNotes ?? ""
    }

    private func scheduleNotesSave(_ text: String) {
        notesTask?.cancel()
        notesTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            recorder.updateUserNotes(text)
        }
    }
}

private struct SavedMeetingDetail: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var nav = HubNavigation.shared
    @ObservedObject var processor: MeetingProcessor
    let meetingID: UUID?

    enum Tab: String, Hashable {
        case notes
        case transcript
    }

    @State private var meeting: Meeting?
    @State private var title = ""
    @State private var userNotes = ""
    @State private var notesTask: Task<Void, Never>?
    @State private var notesDirty = false
    @State private var tab: Tab = .notes
    @State private var templateID: String = NotesTemplate.general.id
    @State private var templates: [NotesTemplate] = NotesTemplate.builtIn
    @State private var speakers: [Speaker] = []
    @State private var confirmDelete = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        Group {
            if let meeting {
                meetingBody(meeting)
            } else {
                ContentUnavailableView(
                    "Meeting unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("This meeting is no longer in the library.")
                )
            }
        }
        .task(id: meetingID) { reload(resetLocal: true) }
        .onChange(of: env.storeGeneration) { _, _ in reload(resetLocal: false) }
        .onDisappear {
            notesTask?.cancel()
            flushNotes()
            commitTitle()
        }
    }

    private func meetingBody(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .focused($isTitleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: isTitleFocused) { _, focused in
                    if !focused { commitTitle() }
                }

            metadataLine(meeting)

            if meeting.status == .processing {
                processingBanner(meeting)
            } else if meeting.status == .failed {
                failedBanner(meeting)
            } else if let progress = processor.progress[meeting.id] {
                processingBanner(meeting, progress: progress)
            }

            Picker("Tab", selection: $tab) {
                Text("Notes").tag(Tab.notes)
                Text("Transcript").tag(Tab.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            Group {
                switch tab {
                case .notes:
                    notesTab(meeting)
                case .transcript:
                    TranscriptTab(meeting: meeting, speakers: speakers)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .navigationTitle(meeting.title)
        .toolbar { detailToolbar(meeting) }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) {
                try? env.store.deleteMeeting(id: meeting.id)
                nav.selectedMeetingID = nil
            }
        } message: {
            Text("The transcript, notes, and recording file will be removed.")
        }
    }

    private func metadataLine(_ meeting: Meeting) -> some View {
        HStack(spacing: 6) {
            Text(meeting.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            Text("·")
            Text(TimeFormat.duration(ms: meeting.durationMs))
            Text("·")
            Text(meeting.source.displayName)
            if !meeting.attendees.isEmpty {
                Text("·")
                Text(meeting.attendees.joined(separator: ", "))
                    .lineLimit(1)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func processingBanner(_ meeting: Meeting, progress: MeetingProcessor.Progress? = nil) -> some View {
        let item = progress ?? processor.progress[meeting.id]
        return HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.stage ?? "Processing")
                    .font(.callout)
                if let fraction = item?.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func failedBanner(_ meeting: Meeting) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(meeting.processingError ?? "Processing failed.")
                .font(.callout)
            Spacer()
            if meeting.audioPath != nil {
                Button("Retry") {
                    processor.reprocess(meetingID: meeting.id)
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func notesTab(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your notes")
                    .font(.headline)
                TextEditor(text: $userNotes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .onChange(of: userNotes) { _, newValue in
                        guard newValue != meeting.userNotes else { return }
                        notesDirty = true
                        scheduleNotesSave(meetingID: meeting.id, notes: newValue)
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("AI notes")
                        .font(.headline)
                    Spacer()
                    if !templates.isEmpty {
                        Picker("Template", selection: $templateID) {
                            ForEach(templates) { template in
                                Text(template.name).tag(template.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                    Button("Regenerate") {
                        Task { await processor.regenerateNotes(meetingID: meeting.id, templateID: templateID) }
                    }
                    .disabled(processor.progress[meeting.id] != nil)
                    Button("Copy") {
                        if let notes = meeting.enhancedNotes { HubClipboard.copy(notes) }
                    }
                    .disabled(meeting.enhancedNotes?.isEmpty != false)
                }

                if meeting.status == .processing {
                    ProgressView(processor.progress[meeting.id]?.stage ?? "Processing…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let markdown = meeting.enhancedNotes, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        MarkdownBlocksView(markdown: markdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if meeting.enhancedBy != nil || meeting.enhancedAt != nil {
                        footnote(meeting)
                    }
                } else if meeting.status == .ready {
                    ContentUnavailableView {
                        Label("No AI notes yet", systemImage: "sparkles")
                    } description: {
                        Text("Generate notes from the transcript using the selected template.")
                    } actions: {
                        Button("Generate") {
                            Task { await processor.regenerateNotes(meetingID: meeting.id, templateID: templateID) }
                        }
                    }
                } else {
                    Text("Notes will appear here after the meeting is processed.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func footnote(_ meeting: Meeting) -> some View {
        HStack(spacing: 0) {
            if let by = meeting.enhancedBy, !by.isEmpty {
                Text("Generated by \(by)")
            }
            if let at = meeting.enhancedAt {
                if meeting.enhancedBy != nil { Text(" · ") }
                Text(at, format: .relative(presentation: .named))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ToolbarContentBuilder
    private func detailToolbar(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Export Markdown…") { exportMarkdown(meeting) }
                Button("Copy transcript") {
                    HubClipboard.copy(meeting.transcriptText(includeTimestamps: true))
                }
                .disabled(meeting.utterances.isEmpty)
                Button("Re-run transcription") {
                    processor.reprocess(meetingID: meeting.id)
                }
                .disabled(meeting.audioPath == nil)
                Button("Reveal recording in Finder") {
                    revealRecording(meeting)
                }
                .disabled(meeting.audioPath == nil)
                Divider()
                Button("Delete meeting", role: .destructive) {
                    confirmDelete = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Meeting actions")
        }
    }

    private func exportMarkdown(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export Markdown"
        panel.nameFieldStringValue = sanitizedFilename(meeting.title) + ".md"
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? MarkdownExport.meeting(meeting).write(to: url, atomically: true, encoding: .utf8)
    }

    private func revealRecording(_ meeting: Meeting) {
        guard let path = meeting.audioPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([env.paths.resolve(relativePath: path)])
    }

    private func sanitizedFilename(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "Meeting" : cleaned
    }

    private func reload(resetLocal: Bool) {
        templates = (try? env.store.allTemplates()) ?? NotesTemplate.builtIn
        speakers = (try? env.store.speakers()) ?? []
        guard let meetingID else {
            meeting = nil
            return
        }
        guard let loaded = try? env.store.meeting(id: meetingID) else {
            meeting = nil
            return
        }
        meeting = loaded
        if resetLocal || !isTitleFocused {
            title = loaded.title
        }
        if resetLocal || !notesDirty {
            userNotes = loaded.userNotes
            notesDirty = false
        }
        if resetLocal {
            let preferred = loaded.enhancedNotesTemplateID ?? env.settings.meetings.defaultTemplateID
            if templates.contains(where: { $0.id == preferred }) {
                templateID = preferred
            } else {
                templateID = templates.first?.id ?? NotesTemplate.general.id
            }
        }
    }

    private func scheduleNotesSave(meetingID: UUID, notes: String) {
        notesTask?.cancel()
        notesTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? env.store.updateUserNotes(meetingID: meetingID, notes: notes)
            notesDirty = false
        }
    }

    private func flushNotes() {
        guard let id = meeting?.id else { return }
        notesTask?.cancel()
        try? env.store.updateUserNotes(meetingID: id, notes: userNotes)
        notesDirty = false
        notesTask = nil
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let meeting, !trimmed.isEmpty, trimmed != meeting.title else { return }
        try? env.store.updateTitle(meetingID: meeting.id, title: trimmed)
    }
}

private struct TranscriptTab: View {
    @EnvironmentObject private var env: AppEnvironment
    let meeting: Meeting
    let speakers: [Speaker]

    @State private var filter = ""
    @State private var renameTarget: SpeakerRenameRequest?
    @State private var editingUtterance: Utterance?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Filter transcript", text: $filter)
                .textFieldStyle(.roundedBorder)

            if meeting.utterances.isEmpty {
                ContentUnavailableView(
                    "No transcript yet",
                    systemImage: "text.alignleft",
                    description: Text(
                        meeting.status == .processing
                            ? "Transcription is still running."
                            : "This meeting doesn’t have a transcript."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No matching utterances",
                    systemImage: "magnifyingglass",
                    description: Text("No transcript lines match “\(filter)”.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groups) { group in
                            utteranceGroup(group)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(item: $renameTarget) { request in
            RenameSpeakerSheet(currentLabel: request.currentLabel) { newName in
                relabel(current: request.currentLabel, newName: newName)
            }
        }
        .sheet(item: $editingUtterance) { utterance in
            UtteranceEditorSheet(utterance: utterance) { text in
                try? env.store.updateUtteranceText(id: utterance.id, text: text)
            }
        }
    }

    private var filteredUtterances: [Utterance] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return meeting.utterances }
        return meeting.utterances.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var groups: [UtteranceGroup] {
        UtteranceGroup.grouping(filteredUtterances)
    }

    private var namedSpeakers: [Speaker] {
        speakers.filter(\.isNamed)
    }

    private func utteranceGroup(_ group: UtteranceGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(TimeFormat.clock(ms: group.startMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    Button("Rename…") {
                        renameTarget = SpeakerRenameRequest(currentLabel: group.speakerLabel)
                    }
                    Button("Mark as me") {
                        markAsMe(current: group.speakerLabel)
                    }
                    if !namedSpeakers.isEmpty {
                        Divider()
                        ForEach(namedSpeakers) { speaker in
                            Button(speaker.displayName) {
                                apply(speaker, current: group.speakerLabel)
                            }
                        }
                    }
                } label: {
                    Text(group.speakerLabel)
                        .font(.headline)
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)

                ForEach(group.utterances) { utterance in
                    Text(utterance.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture(count: 2) { editingUtterance = utterance }
                        .contextMenu {
                            Button("Edit text…") { editingUtterance = utterance }
                            Button("Copy") { HubClipboard.copy(utterance.text) }
                        }
                    if let suggested = utterance.suggestedSpeakerName, !suggested.isEmpty {
                        HStack(spacing: 8) {
                            Text("Is this \(suggested)?")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Yes") {
                                relabel(current: group.speakerLabel, newName: suggested)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func relabel(current: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let speaker: Speaker
        if let existing = speakers.first(where: { $0.displayName.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            speaker = existing
        } else {
            speaker = Speaker(displayName: trimmed)
            try? env.store.upsertSpeaker(speaker)
        }
        try? env.store.relabelSpeaker(
            meetingID: meeting.id,
            currentLabel: current,
            newLabel: speaker.displayName,
            speakerID: speaker.id
        )
    }

    private func markAsMe(current: String) {
        let me = speakers.first(where: \.isSelf)
        try? env.store.relabelSpeaker(
            meetingID: meeting.id,
            currentLabel: current,
            newLabel: Speaker.selfLabel,
            speakerID: me?.id
        )
    }

    private func apply(_ speaker: Speaker, current: String) {
        try? env.store.relabelSpeaker(
            meetingID: meeting.id,
            currentLabel: current,
            newLabel: speaker.displayName,
            speakerID: speaker.id
        )
    }
}

private struct UtteranceGroup: Identifiable {
    var id: UUID
    var speakerLabel: String
    var startMs: Int
    var utterances: [Utterance]

    static func grouping(_ utterances: [Utterance]) -> [UtteranceGroup] {
        var groups: [UtteranceGroup] = []
        for utterance in utterances {
            if let last = groups.last, last.speakerLabel == utterance.speakerLabel {
                groups[groups.count - 1].utterances.append(utterance)
            } else {
                groups.append(
                    UtteranceGroup(
                        id: utterance.id,
                        speakerLabel: utterance.speakerLabel,
                        startMs: utterance.startMs,
                        utterances: [utterance]
                    )
                )
            }
        }
        return groups
    }
}

private struct SpeakerRenameRequest: Identifiable {
    var id: String { currentLabel }
    var currentLabel: String
}

private struct RenameSpeakerSheet: View {
    let currentLabel: String
    let onSave: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(currentLabel: String, onSave: @escaping (String) -> Void) {
        self.currentLabel = currentLabel
        self.onSave = onSave
        _name = State(initialValue: currentLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename speaker")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

private struct UtteranceEditorSheet: View {
    let utterance: Utterance
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(utterance: Utterance, onSave: @escaping (String) -> Void) {
        self.utterance = utterance
        self.onSave = onSave
        _text = State(initialValue: utterance.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit utterance")
                .font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 420, minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 260)
    }
}

struct MarkdownBlocksView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading1(let text):
                    Text(text).font(.title2.weight(.bold)).padding(.top, 8)
                case .heading2(let text):
                    Text(text).font(.title3.weight(.semibold)).padding(.top, 6)
                case .heading3(let text):
                    Text(text).font(.headline).padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(text)
                    }
                case .body(let text):
                    Text(text)
                case .blank:
                    Spacer().frame(height: 6)
                }
            }
        }
    }

    private enum Block {
        case heading1(String)
        case heading2(String)
        case heading3(String)
        case bullet(String)
        case body(String)
        case blank
    }

    private var blocks: [Block] {
        markdown.components(separatedBy: "\n").map { line in
            if line.hasPrefix("### ") { return .heading3(String(line.dropFirst(4))) }
            if line.hasPrefix("## ") { return .heading2(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .heading1(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            if line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
            return .body(line)
        }
    }
}
