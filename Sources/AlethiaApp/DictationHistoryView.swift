import AppKit
import SwiftUI
import AlethiaCore
import AlethiaDictation
import AlethiaKnowledge

struct DictationHistoryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding var selection: UUID?

    @State private var dictations: [Dictation] = []
    @State private var confirmClear = false

    var body: some View {
        Group {
            if dictations.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "mic",
                    description: Text("Hold \(env.settings.dictation.hotkey.symbol) to dictate into any app.")
                )
            } else {
                List(selection: $selection) {
                    ForEach(dictations) { dictation in
                        DictationRow(dictation: dictation)
                            .tag(dictation.id)
                            .contextMenu {
                                Button("Copy") { HubClipboard.copy(dictation.displayText) }
                                Button("Delete", role: .destructive) {
                                    delete(dictation.id)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Dictation history")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear history…") { confirmClear = true }
                    .disabled(dictations.isEmpty)
            }
        }
        .confirmationDialog("Clear dictation history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) {
                try? env.store.deleteAllDictations()
                selection = nil
            }
        } message: {
            Text("All saved dictations will be deleted. Dictionary entries learned from edits are kept.")
        }
        .task(id: env.storeGeneration) {
            dictations = (try? env.store.listDictations(limit: 500)) ?? []
            if let selection, !dictations.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
    }

    private func delete(_ id: UUID) {
        try? env.store.deleteDictation(id: id)
        if selection == id { selection = nil }
    }
}

private struct DictationRow: View {
    let dictation: Dictation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dictation.displayText)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(dictation.targetAppName ?? "Unknown app")
                Text("·")
                Text(dictation.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text(TimeFormat.clock(ms: dictation.durationMs))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct DictationDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    let dictationID: UUID?

    @State private var dictation: Dictation?
    @State private var editedText = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let dictation {
                detail(dictation)
            } else {
                ContentUnavailableView(
                    "Select a dictation",
                    systemImage: "text.cursor",
                    description: Text("Choose an item from the history list to inspect or edit it.")
                )
            }
        }
        .task(id: dictationID) { reload(resetEditor: true) }
        .onChange(of: env.storeGeneration) { _, _ in reload(resetEditor: false) }
    }

    private func detail(_ dictation: Dictation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dictation.targetAppName ?? "Unknown app")
                            .font(.title2.weight(.semibold))
                        HStack(spacing: 6) {
                            Text(dictation.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                            Text("·")
                            Text(TimeFormat.clock(ms: dictation.durationMs))
                            Text("·")
                            Text("\(dictation.wordCount) words")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy") { HubClipboard.copy(dictation.displayText) }
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }

                labeledBlock("Raw", dictation.rawText)
                labeledBlock("Inserted", dictation.finalText)
                if let previous = dictation.editedText, !previous.isEmpty {
                    labeledBlock("Previously edited", previous)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Edit")
                        .font(.headline)
                    TextEditor(text: $editedText)
                        .font(.body)
                        .frame(minHeight: 140)
                    HStack {
                        Spacer()
                        Button("Save") { saveEdit(dictation) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(editedText == dictation.displayText)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Dictation")
        .confirmationDialog("Delete this dictation?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? env.store.deleteDictation(id: dictation.id)
            }
        }
    }

    private func labeledBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text.isEmpty ? "—" : text)
                .textSelection(.enabled)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func saveEdit(_ dictation: Dictation) {
        let original = dictation.displayText
        let newText = editedText
        try? env.store.updateDictationEdit(id: dictation.id, editedText: newText)
        if newText != original {
            env.dictation.learn(inserted: original, edited: newText)
        }
    }

    private func reload(resetEditor: Bool) {
        guard let dictationID else {
            dictation = nil
            return
        }
        let loaded = try? env.store.dictation(id: dictationID)
        dictation = loaded
        if resetEditor, let loaded {
            editedText = loaded.displayText
        }
    }
}
