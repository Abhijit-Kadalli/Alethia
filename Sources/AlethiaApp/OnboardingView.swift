import AppKit
import SwiftUI
import AlethiaCore
import AlethiaDictation
import AlethiaSpeech

/// First-run flow: what Alethia does → permissions → model download → hotkey → done.
struct OnboardingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome, permissions, models, hotkey, done
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            Divider()
            footer
                .padding(16)
        }
        .background(.background)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .models: ModelsStep(models: env.models)
        case .hotkey: HotkeyStep()
        case .done: DoneStep()
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome && step != .done {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                    .keyboardShortcut(.cancelAction)
            }
            Button(primaryTitle) { advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .models: return env.models.recognizerInstalled(for: env.settings.speechModel) ? "Continue" : "Skip for now"
        case .done: return "Open Alethia"
        default: return "Continue"
        }
    }

    private var canAdvance: Bool {
        if step == .models, env.models.activeDownloads > 0 { return false }
        return true
    }

    private func advance() {
        if step == .done {
            env.completeOnboarding()
            openWindow(id: WindowID.hub)
            dismiss()
            return
        }
        step = Step(rawValue: step.rawValue + 1) ?? .done
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Alethia").font(.system(size: 34, weight: .bold))
            Text("Talk instead of type, and get meeting notes written for you. Everything runs on this Mac: your audio and transcripts never leave it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(symbol: "mic.fill", title: "Dictate anywhere",
                           text: "Hold a key, speak, release. Clean, punctuated text appears in whatever app you're in.")
                FeatureRow(symbol: "person.2.wave.2.fill", title: "Meeting notes",
                           text: "Record calls with speaker labels and get structured notes when the meeting ends.")
                FeatureRow(symbol: "lock.shield.fill", title: "Private by design",
                           text: "Open-source speech models on the Neural Engine. No account, no cloud.")
            }
            .padding(.top, 8)
            Spacer()
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PermissionsStep: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var microphone: PermissionState = .notDetermined
    @State private var accessibility = false
    @State private var screenRecording = false
    @State private var calendar: PermissionState = .notDetermined
    @State private var poller: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Permissions").font(.largeTitle.bold())
            Text("macOS asks for each of these separately. Alethia only uses them while you dictate or record.")
                .foregroundStyle(.secondary)

            PermissionRow(
                symbol: "mic.fill", title: "Microphone", required: true,
                detail: "Needed to hear you.",
                granted: microphone == .granted,
                actionTitle: microphone == .denied ? "Open System Settings" : "Allow"
            ) {
                if microphone == .denied {
                    env.permissions.openMicrophoneSettings()
                } else {
                    Task { microphone = await env.permissions.requestMicrophone() }
                }
            }
            PermissionRow(
                symbol: "keyboard", title: "Accessibility", required: true,
                detail: "Lets the dictation hotkey work in every app and types the text where your cursor is.",
                granted: accessibility,
                actionTitle: "Open System Settings"
            ) {
                _ = env.permissions.accessibilityTrusted(prompt: true)
                env.permissions.openAccessibilitySettings()
            }
            PermissionRow(
                symbol: "rectangle.inset.filled.and.person.filled", title: "Screen & system audio", required: false,
                detail: "Captures the other side of video calls so meeting transcripts include everyone. Alethia never records the screen.",
                granted: screenRecording,
                actionTitle: "Allow"
            ) {
                if !env.permissions.requestScreenRecording() {
                    env.permissions.openScreenRecordingSettings()
                }
            }
            PermissionRow(
                symbol: "calendar", title: "Calendar", required: false,
                detail: "Names meetings after the event you're in and lists attendees.",
                granted: calendar == .granted,
                actionTitle: calendar == .denied ? "Open System Settings" : "Allow"
            ) {
                if calendar == .denied {
                    env.permissions.openCalendarSettings()
                } else {
                    Task {
                        calendar = await env.calendar.requestAccess()
                        if calendar == .granted { env.settings.meetings.useCalendar = true }
                    }
                }
            }
            Spacer()
        }
        .onAppear { refresh(); startPolling() }
        .onDisappear { poller?.cancel() }
    }

    private func refresh() {
        microphone = env.permissions.microphoneState()
        accessibility = env.permissions.accessibilityTrusted(prompt: false)
        screenRecording = env.permissions.screenRecordingGranted()
        calendar = env.calendar.authorizationState
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refresh()
                if accessibility { env.refreshPermissions() }
            }
        }
    }
}

struct PermissionRow: View {
    let symbol: String
    let title: String
    let required: Bool
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if !required {
                        Text("Optional").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button(actionTitle, action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ModelsStep: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var models: ModelManager
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Speech model").font(.largeTitle.bold())
            Text("Alethia keeps its download tiny and fetches the open-source speech models once, about 650 MB. They run on the Neural Engine and stay on this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Language", selection: $env.settings.speechModel) {
                ForEach(SpeechModelVariant.allCases, id: \.self) { variant in
                    Text(variant.displayName).tag(variant)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(models.activeDownloads > 0)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(ModelComponent.required(for: env.settings.speechModel)) { component in
                    ModelRow(component: component, state: models.state(of: component))
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            HStack {
                if models.allInstalled(for: env.settings.speechModel) {
                    Label("Ready to go", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else if models.activeDownloads > 0 {
                    ProgressView(value: models.overallProgress(for: env.settings.speechModel))
                        .frame(maxWidth: 260)
                    Text("\(Int(models.overallProgress(for: env.settings.speechModel) * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Button("Download models") {
                        error = nil
                        Task {
                            do {
                                try await env.models.downloadRequired(for: env.settings.speechModel)
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
    }
}

struct ModelRow: View {
    let component: ModelComponent
    let state: ModelInstallState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(component.displayName).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .downloading(let fraction, _) = state {
                ProgressView(value: fraction).frame(width: 90).controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch state {
        case .installed: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.circle.fill"
        case .notInstalled: return "circle"
        }
    }

    private var color: Color {
        switch state {
        case .installed: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var subtitle: String {
        switch state {
        case .downloading(_, let phase): return phase
        case .failed(let message): return message
        default: return component.detail
        }
    }
}

struct HotkeyStep: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your dictation key").font(.largeTitle.bold())
            Text("Hold it to talk, release to insert. You can switch to tap-to-toggle in Settings.")
                .foregroundStyle(.secondary)
            Picker("Hotkey", selection: $env.settings.dictation.hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .pickerStyle(.radioGroup)
            Picker("Mode", selection: $env.settings.dictation.activation) {
                ForEach(DictationActivation.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            HotkeyPreview(hotkey: env.settings.dictation.hotkey)
            Spacer()
        }
    }
}

private struct HotkeyPreview: View {
    let hotkey: DictationHotkey

    var body: some View {
        HStack(spacing: 14) {
            Text(hotkey.symbol)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .frame(minWidth: 64, minHeight: 56)
                .padding(.horizontal, 12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold \(hotkey.displayName)").font(.headline)
                Text("Speak naturally. Say \"new line\", \"period\", or \"scratch that\" as you go.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

private struct DoneStep: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("You're set").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(symbol: "menubar.arrow.up.rectangle", title: "Alethia lives in the menu bar",
                           text: "Click the waveform icon for recording controls, recent meetings, and settings.")
                FeatureRow(symbol: hotkeySymbol, title: "Hold \(env.settings.dictation.hotkey.displayName) to dictate",
                           text: "Put your cursor in any text field first. A small overlay shows what Alethia hears.")
                FeatureRow(symbol: "record.circle", title: "Record a meeting",
                           text: "Alethia notices when a call starts and offers to take notes. Or start one from the menu bar.")
            }
            Spacer()
        }
    }

    private var hotkeySymbol: String {
        env.settings.dictation.hotkey == .fn ? "globe" : "command"
    }
}
