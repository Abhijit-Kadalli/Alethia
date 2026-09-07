import SwiftUI
import AlethiaCore
import AlethiaKnowledge

struct SpeakersView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding var selection: UUID?

    @State private var speakers: [Speaker] = []
    @State private var selectedIDs = Set<UUID>()
    @State private var confirmMerge = false
    @State private var confirmDelete: Speaker?

    var body: some View {
        Group {
            if speakers.isEmpty {
                ContentUnavailableView(
                    "No speakers yet",
                    systemImage: "person.crop.circle.badge.checkmark",
                    description: Text("Named speakers are recognized automatically in future meetings.")
                )
            } else {
                List(selection: $selectedIDs) {
                    ForEach(speakers) { speaker in
                        SpeakerRow(speaker: speaker)
                            .tag(speaker.id)
                            .contextMenu {
                                Button("Delete…", role: .destructive) {
                                    confirmDelete = speaker
                                }
                            }
                    }
                }
                .onChange(of: selectedIDs) { _, newValue in
                    if newValue.count == 1 {
                        selection = newValue.first
                    } else if newValue.isEmpty {
                        selection = nil
                    }
                }
            }
        }
        .navigationTitle("Speakers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Merge…") { confirmMerge = true }
                    .disabled(selectedIDs.count != 2)
                    .help("Select two speakers to merge")
            }
        }
        .confirmationDialog("Merge speakers?", isPresented: $confirmMerge, titleVisibility: .visible) {
            if let pair = mergePair {
                Button("Keep \(pair.keep.displayName)") {
                    try? env.store.mergeSpeakers(keep: pair.keep.id, remove: pair.remove.id)
                    selectedIDs = [pair.keep.id]
                    selection = pair.keep.id
                }
                Button("Keep \(pair.remove.displayName)") {
                    try? env.store.mergeSpeakers(keep: pair.remove.id, remove: pair.keep.id)
                    selectedIDs = [pair.remove.id]
                    selection = pair.remove.id
                }
            }
        } message: {
            Text("Utterances from the removed speaker will be attributed to the one you keep.")
        }
        .confirmationDialog(
            "Delete \(confirmDelete?.displayName ?? "this speaker")?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = confirmDelete?.id {
                    try? env.store.deleteSpeaker(id: id)
                    selectedIDs.remove(id)
                    if selection == id { selection = nil }
                }
                confirmDelete = nil
            }
        } message: {
            Text("Existing transcripts keep their labels. This person will no longer be recognized automatically.")
        }
        .task(id: env.storeGeneration) {
            speakers = (try? env.store.speakers()) ?? []
            let valid = Set(speakers.map(\.id))
            selectedIDs = selectedIDs.intersection(valid)
            if let selection, !valid.contains(selection) {
                self.selection = nil
            }
        }
    }

    private var mergePair: (keep: Speaker, remove: Speaker)? {
        let chosen = speakers.filter { selectedIDs.contains($0.id) }
        guard chosen.count == 2 else { return nil }
        return (chosen[0], chosen[1])
    }
}

private struct SpeakerRow: View {
    @EnvironmentObject private var env: AppEnvironment
    let speaker: Speaker
    @State private var name: String

    init(speaker: Speaker) {
        self.speaker = speaker
        _name = State(initialValue: speaker.displayName)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .onSubmit { save() }
                    if speaker.isSelf {
                        Text("You")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
                Text(heardLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .onDisappear { save() }
    }

    private var heardLabel: String {
        speaker.sampleCount == 1 ? "heard 1 time" : "heard \(speaker.sampleCount) times"
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != speaker.displayName else { return }
        var updated = speaker
        updated.displayName = trimmed
        updated.updatedAt = Date()
        try? env.store.upsertSpeaker(updated)
    }
}

struct SpeakerDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding var selection: UUID?

    @State private var speaker: Speaker?
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let speaker {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Name", text: $name)
                        .font(.title2.weight(.semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { saveName(speaker) }

                    HStack(spacing: 8) {
                        if speaker.isSelf {
                            Text("You")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                        Text(speaker.sampleCount == 1 ? "heard 1 time" : "heard \(speaker.sampleCount) times")
                            .foregroundStyle(.secondary)
                    }

                    Text("Named speakers are recognized automatically in future meetings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Save name") { saveName(speaker) }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || name == speaker.displayName)
                        Button("Delete…", role: .destructive) { confirmDelete = true }
                    }
                    Spacer()
                }
                .padding(20)
                .confirmationDialog("Delete \(speaker.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        try? env.store.deleteSpeaker(id: speaker.id)
                        selection = nil
                    }
                } message: {
                    Text("Existing transcripts keep their labels. This person will no longer be recognized automatically.")
                }
            } else {
                ContentUnavailableView(
                    "Select a speaker",
                    systemImage: "person.crop.circle.badge.checkmark",
                    description: Text("Named speakers are recognized automatically in future meetings. Select two in the list to merge them.")
                )
            }
        }
        .task(id: selection) { reload() }
        .onChange(of: env.storeGeneration) { _, _ in reload() }
    }

    private func saveName(_ speaker: Speaker) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != speaker.displayName else { return }
        var updated = speaker
        updated.displayName = trimmed
        updated.updatedAt = Date()
        try? env.store.upsertSpeaker(updated)
    }

    private func reload() {
        guard let selection else {
            speaker = nil
            return
        }
        let loaded = try? env.store.speaker(id: selection)
        speaker = loaded
        if let loaded {
            name = loaded.displayName
        }
    }
}
