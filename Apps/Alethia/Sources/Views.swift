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

            Toggle("Include system audio", isOn: $model.includeSystemAudio)
                .padding(.horizontal, 12)

            Divider()

            Button("Open Hub") { openWindow(id: "hub") }
            Button("Quit Alethia") { NSApplication.shared.terminate(nil) }
        }
        .frame(minWidth: 240)
    }
}

struct HubView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var renameDrafts: [UUID: String] = [:]
    @State private var showOnboarding = true

    private let speakerColors: [Color] = [
        Color(red: 0.20, green: 0.45, blue: 0.55),
        Color(red: 0.55, green: 0.35, blue: 0.20),
        Color(red: 0.30, green: 0.50, blue: 0.30),
        Color(red: 0.50, green: 0.28, blue: 0.40)
    ]

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
                            Text(hit.kind.rawValue.uppercased())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
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
                            .disabled((renameDrafts[speaker.id] ?? speaker.displayName)
                                .trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if model.speakers.isEmpty {
                        Text("Speakers appear after ambient conversations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    ForEach(Array(session.utterances.enumerated()), id: \.element.id) { idx, u in
                        HStack(alignment: .top) {
                            Text(u.speakerLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColors[idx % speakerColors.count])
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
                        description: Text("Start ambient listening from the menu bar. Hold Right Option to dictate.")
                    )
                }
            }
        }
        .onAppear { model.reload() }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
    }
}

struct OnboardingView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Alethia")
                .font(.title.weight(.semibold))
            Text("Fully local ambient capture + speak-to-type. Audio and transcripts stay on your Mac.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Microphone — ambient conversations & dictation", systemImage: "mic")
                Label("Accessibility — type dictated text into other apps", systemImage: "keyboard")
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
