import AppKit
import SwiftUI
import AlethiaCore
import AlethiaDictation
import AlethiaKnowledge
import AlethiaMeetings

struct MenuBarIcon: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        MenuBarIconBody(recorder: env.recorder, dictation: env.dictation)
            .background(WindowOpenerBinder())
    }
}

private struct MenuBarIconBody: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var dictation: DictationController

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
    }

    private var symbol: String {
        if recorder.isRecording { return "record.circle.fill" }
        switch dictation.state {
        case .listening: return "waveform.circle.fill"
        case .processing: return "ellipsis.circle"
        case .idle: return "waveform.circle"
        }
    }
}

/// Nested controllers are observed explicitly; `AppEnvironment` alone does not republish them.
struct MenuBarContent: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        MenuBarBody(recorder: env.recorder, dictation: env.dictation, processor: env.processor, models: env.models)
    }
}

private struct MenuBarBody: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var dictation: DictationController
    @ObservedObject var processor: MeetingProcessor
    @ObservedObject var models: ModelManager
    @Environment(\.openWindow) private var openWindow
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            dictationRow
            meetingRow
            if let call = env.detectedCall, !recorder.isRecording {
                detectedCallBanner(call)
            }
            if !processor.progress.isEmpty {
                processingRows
            }
            if let lastError {
                Text(lastError).font(.caption).foregroundStyle(.red)
            }
            Divider()
            recentMeetings
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Alethia").font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !models.recognizerInstalled(for: env.settings.speechModel) {
                Label("Model missing", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .help("The speech model is not downloaded. Open Settings › Models.")
            }
        }
    }

    private var statusLine: String {
        if recorder.isRecording {
            return "Recording · \(TimeFormat.clock(ms: recorder.elapsedMs))"
        }
        switch dictation.state {
        case .listening: return "Listening…"
        case .processing: return "Transcribing…"
        case .idle:
            return dictation.hotkeyActive
                ? "Hold \(env.settings.dictation.hotkey.symbol) to dictate"
                : "Dictation hotkey off — grant Accessibility"
        }
    }

    private var dictationRow: some View {
        Button {
            dictation.toggle()
        } label: {
            Label(dictation.state == .idle ? "Start dictation" : "Stop dictation",
                  systemImage: dictation.state == .idle ? "mic" : "stop.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuRowStyle())
        .disabled(dictation.state == .processing)
    }

    private var meetingRow: some View {
        Button {
            Task {
                if recorder.isRecording {
                    await recorder.stop()
                } else {
                    do {
                        try await recorder.start()
                        openWindow(id: WindowID.hub)
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
            }
        } label: {
            Label(recorder.isRecording ? "Stop meeting" : "Record meeting",
                  systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuRowStyle(tint: recorder.isRecording ? .red : nil))
        .disabled(recorder.phase == .starting || recorder.phase == .stopping)
    }

    private func detectedCallBanner(_ call: MeetingDetector.Detection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.badge.waveform.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(call.appName ?? "A call") is running").font(.callout)
                Text("Record notes for this meeting?").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Record") { env.startDetectedMeeting(); openWindow(id: WindowID.hub) }
                .controlSize(.small)
            Button { env.dismissDetectedCall() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var processingRows: some View {
        ForEach(Array(processor.progress.values).sorted { $0.meetingID.uuidString < $1.meetingID.uuidString }, id: \.meetingID) { item in
            VStack(alignment: .leading, spacing: 3) {
                Text(item.stage).font(.caption)
                ProgressView(value: item.fraction).controlSize(.small)
            }
        }
    }

    private var recentMeetings: some View {
        let meetings = (try? env.store.listMeetings(limit: 4)) ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if meetings.isEmpty {
                Text("No meetings yet").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(meetings) { meeting in
                Button {
                    HubNavigation.shared.select(meetingID: meeting.id)
                    openWindow(id: WindowID.hub)
                } label: {
                    HStack {
                        Text(meeting.title).lineLimit(1)
                        Spacer()
                        Text(meeting.startedAt, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowStyle())
            }
        }
        .id(env.storeGeneration)
    }

    private var footer: some View {
        HStack {
            Button("Open Alethia") {
                openWindow(id: WindowID.hub)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o")
            Button("Settings…") {
                HubNavigation.shared.select(section: .settings)
                openWindow(id: WindowID.hub)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

struct MenuRowStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .foregroundStyle(tint ?? .primary)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

enum TimeFormat {
    static func clock(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func duration(ms: Int) -> String {
        let minutes = max(1, (ms + 30_000) / 60_000)
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
