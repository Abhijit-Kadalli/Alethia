import SwiftUI
import AlethiaCore
import AlethiaKnowledge

struct VocabularyView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding var selectedDictionaryID: UUID?
    @Binding var selectedSnippetID: UUID?

    enum Pane: String, Hashable {
        case dictionary
        case snippets
    }

    @State private var pane: Pane = .dictionary
    @State private var entries: [DictionaryEntry] = []
    @State private var snippets: [Snippet] = []
    @State private var spoken = ""
    @State private var written = ""
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Vocabulary", selection: $pane) {
                Text("Dictionary").tag(Pane.dictionary)
                Text("Snippets").tag(Pane.snippets)
            }
            .pickerStyle(.segmented)
            .padding(12)

            Group {
                switch pane {
                case .dictionary:
                    dictionaryList
                case .snippets:
                    snippetList
                }
            }
        }
        .navigationTitle("Dictionary & snippets")
        .task(id: env.storeGeneration) { reload() }
        .onChange(of: pane) { _, newPane in
            if newPane == .dictionary {
                selectedSnippetID = nil
            } else {
                selectedDictionaryID = nil
            }
        }
    }

    private var dictionaryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Spoken", text: $spoken)
                    .textFieldStyle(.roundedBorder)
                TextField("Written", text: $written)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addDictionaryEntry() }
                    .disabled(!canAddDictionary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if entries.isEmpty {
                ContentUnavailableView(
                    "No dictionary entries",
                    systemImage: "character.book.closed",
                    description: Text("Add a spoken form and the text you want written instead.")
                )
            } else {
                List(selection: $selectedDictionaryID) {
                    ForEach(entries) { entry in
                        DictionaryEntryRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    try? env.store.deleteDictionaryEntry(id: entry.id)
                                }
                            }
                    }
                }
            }
        }
    }

    private var snippetList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Trigger phrase", text: $trigger)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addSnippet() }
                        .disabled(!canAddSnippet)
                        .keyboardShortcut(.defaultAction)
                }
                TextField("Expansion", text: $expansion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if snippets.isEmpty {
                ContentUnavailableView(
                    "No snippets",
                    systemImage: "text.badge.plus",
                    description: Text("Add a trigger such as \"insert my signature\" and the text it should expand to.")
                )
            } else {
                List(selection: $selectedSnippetID) {
                    ForEach(snippets) { snippet in
                        SnippetRow(snippet: snippet)
                            .tag(snippet.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    try? env.store.deleteSnippet(id: snippet.id)
                                }
                            }
                    }
                }
            }
        }
    }

    private var canAddDictionary: Bool {
        !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canAddSnippet: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addDictionaryEntry() {
        let spokenValue = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let writtenValue = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenValue.isEmpty, !writtenValue.isEmpty else { return }
        try? env.store.upsertDictionaryEntry(DictionaryEntry(spoken: spokenValue, written: writtenValue, origin: .user))
        spoken = ""
        written = ""
    }

    private func addSnippet() {
        let triggerValue = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansionValue = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !triggerValue.isEmpty, !expansionValue.isEmpty else { return }
        try? env.store.upsertSnippet(Snippet(trigger: triggerValue, expansion: expansionValue))
        trigger = ""
        expansion = ""
    }

    private func reload() {
        entries = (try? env.store.dictionaryEntries()) ?? []
        snippets = (try? env.store.snippets()) ?? []
        if let selectedDictionaryID, !entries.contains(where: { $0.id == selectedDictionaryID }) {
            self.selectedDictionaryID = nil
        }
        if let selectedSnippetID, !snippets.contains(where: { $0.id == selectedSnippetID }) {
            self.selectedSnippetID = nil
        }
    }
}

private struct DictionaryEntryRow: View {
    @EnvironmentObject private var env: AppEnvironment
    let entry: DictionaryEntry
    @State private var spoken: String
    @State private var written: String

    init(entry: DictionaryEntry) {
        self.entry = entry
        _spoken = State(initialValue: entry.spoken)
        _written = State(initialValue: entry.written)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Spoken", text: $spoken)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField("Written", text: $written)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            if entry.origin == .learned {
                Text("learned")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text("\(entry.useCount)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Times used")
            Button(role: .destructive) {
                try? env.store.deleteDictionaryEntry(id: entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .onDisappear { save() }
    }

    private func save() {
        let spokenValue = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let writtenValue = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenValue.isEmpty, !writtenValue.isEmpty else { return }
        guard spokenValue != entry.spoken || writtenValue != entry.written else { return }
        var updated = entry
        updated.spoken = spokenValue
        updated.written = writtenValue
        try? env.store.upsertDictionaryEntry(updated)
    }
}

private struct SnippetRow: View {
    @EnvironmentObject private var env: AppEnvironment
    let snippet: Snippet
    @State private var trigger: String
    @State private var expansion: String

    init(snippet: Snippet) {
        self.snippet = snippet
        _trigger = State(initialValue: snippet.trigger)
        _expansion = State(initialValue: snippet.expansion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Trigger", text: $trigger)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Text("\(snippet.useCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Times used")
                Button(role: .destructive) {
                    try? env.store.deleteSnippet(id: snippet.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            TextField("Expansion", text: $expansion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .onSubmit { save() }
        }
        .padding(.vertical, 4)
        .onDisappear { save() }
    }

    private func save() {
        let triggerValue = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansionValue = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !triggerValue.isEmpty, !expansionValue.isEmpty else { return }
        guard triggerValue != snippet.trigger || expansionValue != snippet.expansion else { return }
        var updated = snippet
        updated.trigger = triggerValue
        updated.expansion = expansionValue
        try? env.store.upsertSnippet(updated)
    }
}

struct VocabularyDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let dictionaryID: UUID?
    let snippetID: UUID?

    @State private var entry: DictionaryEntry?
    @State private var snippet: Snippet?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How this works")
                .font(.title2.weight(.semibold))
            Text("Dictionary entries replace what the recognizer hears with what you want written. Snippets expand a trigger phrase (\"insert my signature\") into longer text.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let entry {
                GroupBox("Selected entry") {
                    LabeledContent("Spoken", value: entry.spoken)
                    LabeledContent("Written", value: entry.written)
                    LabeledContent("Origin", value: entry.origin == .learned ? "Learned" : "User")
                    LabeledContent("Used", value: "\(entry.useCount) times")
                }
            } else if let snippet {
                GroupBox("Selected snippet") {
                    LabeledContent("Trigger", value: snippet.trigger)
                    Text(snippet.expansion)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            } else {
                ContentUnavailableView(
                    "Select an item",
                    systemImage: "character.book.closed",
                    description: Text("Choose a dictionary entry or snippet to inspect it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: reloadID) { reload() }
        .onChange(of: env.storeGeneration) { _, _ in reload() }
    }

    private var reloadID: String {
        "\(dictionaryID?.uuidString ?? "")-\(snippetID?.uuidString ?? "")"
    }

    private func reload() {
        if let dictionaryID {
            entry = try? env.store.dictionaryEntry(id: dictionaryID)
            snippet = nil
        } else if let snippetID {
            snippet = try? env.store.snippet(id: snippetID)
            entry = nil
        } else {
            entry = nil
            snippet = nil
        }
    }
}
