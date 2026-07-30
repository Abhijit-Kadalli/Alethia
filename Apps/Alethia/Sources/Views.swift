import AppKit
import SwiftUI
import AlethiaCore

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            Button(model.ambientState == .stopped || model.ambientState == .paused
                   ? "Start Ambient Listening"
                   : "Stop Ambient Listening") {
                model.toggleAmbient()
            }

            if model.isDictating {
                Button("Finish Dictation") { model.endDictation() }
            } else {
                Button("Start Dictation") { model.beginDictation() }
            }

            Divider()

            Button("Open Hub") { openWindow(id: "hub") }
            Button("Quit Alethia") { NSApplication.shared.terminate(nil) }
        }
        .frame(minWidth: 220)
    }
}

struct HubView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var renameDrafts: [UUID: String] = [:]

    var body: some View {
        NavigationSplitView {
            List {
                Section("Knowledge") {
                    TextField("Search transcripts & dictations", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: query) { _, value in
                            model.search(value)
                        }
                    ForEach(model.searchHits) { hit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.title).font(.headline)
                            Text(hit.snippet).font(.caption).foregroundStyle(.secondary)
                        }
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
                            .disabled((renameDrafts[speaker.id] ?? speaker.displayName).trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            List(model.sessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(session.title ?? "Conversation").font(.headline)
                        Spacer()
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(session.source.rawValue.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(session.utterances) { u in
                        HStack(alignment: .top) {
                            Text(u.speakerLabel)
                                .font(.caption.weight(.semibold))
                                .frame(width: 90, alignment: .leading)
                            Text(u.text)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No conversations yet",
                        systemImage: "ear",
                        description: Text("Start ambient listening from the menu bar.")
                    )
                }
            }
        }
        .onAppear { model.reload() }
    }
}
