import AppKit
import Foundation
import SwiftUI
import AlethiaASR
import AlethiaAudio
import AlethiaCore
import AlethiaDiarization
import AlethiaDictation
import AlethiaKnowledge

@main
struct AlethiaApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("Alethia", systemImage: appModel.menuBarSymbol) {
            MenuBarView()
                .environmentObject(appModel)
        }
        .menuBarExtraStyle(.menu)

        Window("Alethia", id: "hub") {
            HubView()
                .environmentObject(appModel)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var ambientState: AmbientState = .stopped
    @Published var sessions: [ConversationSession] = []
    @Published var speakers: [SpeakerProfile] = []
    @Published var searchHits: [KnowledgeHit] = []
    @Published var statusMessage: String = "Ready"
    @Published var isDictating = false

    let store: KnowledgeStore
    let ambient: AmbientPipeline
    let asr: ASRService
    let dictation: DictationController
    let gallery: SpeakerGallery
    let diarizer: DiarizationService
    let permissions = PermissionGate()

    var menuBarSymbol: String {
        if isDictating { return "mic.fill" }
        switch ambientState {
        case .listening, .inConversation: return "waveform"
        case .paused: return "pause.circle"
        case .stopped: return "ear"
        }
    }

    init() {
        do {
            let store = try KnowledgeStore()
            self.store = store
            self.asr = ASRService()
            self.dictation = DictationController(asr: asr, store: store, permissions: permissions)
            self.gallery = try SpeakerGallery(store: store)
            self.diarizer = DiarizationService(gallery: gallery)
            self.ambient = AmbientPipeline()
            ambient.onConversationClosed = { [weak self] segment in
                Task { @MainActor in
                    await self?.finalize(segment: segment)
                }
            }
            reload()
        } catch {
            fatalError("Failed to start Alethia: \(error)")
        }
    }

    func reload() {
        sessions = (try? store.recentSessions()) ?? []
        speakers = (try? store.allSpeakers()) ?? []
    }

    func toggleAmbient() {
        Task {
            do {
                if ambientState == .stopped || ambientState == .paused {
                    try await permissions.requireMicrophone()
                    try ambient.start()
                    ambientState = ambient.state
                    statusMessage = "Ambient listening"
                } else {
                    ambient.stop()
                    ambientState = .stopped
                    statusMessage = "Ambient stopped"
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func beginDictation() {
        Task {
            do {
                try await permissions.requireMicrophone()
                try dictation.begin()
                isDictating = true
                statusMessage = "Dictating…"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func endDictation() {
        Task {
            do {
                _ = try await dictation.end(targetBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
                isDictating = false
                statusMessage = "Dictation saved"
                reload()
            } catch {
                isDictating = false
                statusMessage = error.localizedDescription
            }
        }
    }

    func search(_ query: String) {
        searchHits = (try? store.search(query: query)) ?? []
    }

    func renameSpeaker(_ speaker: SpeakerProfile, to name: String) {
        do {
            try gallery.rename(id: speaker.id, to: name)
            reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func finalize(segment: ConversationSegment) async {
        do {
            let transcripts = try await asr.transcribe(pcm: segment.pcm)
            let diarized = try diarizer.diarize(
                pcm: segment.pcm,
                sampleRate: 16_000,
                transcripts: transcripts.map { ($0.startMs, $0.endMs, $0.text) }
            )
            var session = ConversationSession(
                title: "Conversation",
                startedAt: segment.startedAt,
                endedAt: segment.endedAt ?? Date(),
                source: .ambient,
                utterances: diarized.map {
                    Utterance(
                        speakerID: $0.speakerID,
                        speakerLabel: $0.speakerLabel,
                        startMs: $0.startMs,
                        endMs: $0.endMs,
                        text: $0.text
                    )
                }
            )
            if let first = session.utterances.first {
                session.title = String(first.text.prefix(48))
            }
            try store.saveSession(session)
            ambientState = ambient.state
            statusMessage = "Saved conversation"
            reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
