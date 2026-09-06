import AppKit
import SwiftUI
import UserNotifications
import AlethiaCore

enum WindowID {
    static let hub = "hub"
    static let onboarding = "onboarding"
}

@main
struct AlethiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    init() {
        let environment = AppEnvironment()
        _env = StateObject(wrappedValue: environment)
        AppDelegate.environment = environment
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(env)
        } label: {
            MenuBarIcon()
                .environmentObject(env)
        }
        .menuBarExtraStyle(.window)

        Window("Alethia", id: WindowID.hub) {
            HubView()
                .environmentObject(env)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Start / Stop Dictation") { env.dictation.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(env.recorder.isRecording ? "Stop Meeting Recording" : "Start Meeting Recording") {
                    Task {
                        if env.recorder.isRecording {
                            await env.recorder.stop()
                        } else {
                            try? await env.recorder.start()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Window("Welcome to Alethia", id: WindowID.onboarding) {
            OnboardingView()
                .environmentObject(env)
                .frame(width: 640, height: 520)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Handles launch, notification actions, and reopen (menu-bar apps have no Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            guard let env = AppDelegate.environment else { return }
            if env.settings.didCompleteOnboarding {
                env.start()
            } else {
                WindowOpener.shared.open(WindowID.onboarding)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in WindowOpener.shared.open(WindowID.hub) }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in AppDelegate.environment?.refreshPermissions() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == NotificationCategory.meetingDetected else { return }
        await MainActor.run {
            let env = AppDelegate.environment
            switch response.actionIdentifier {
            case NotificationAction.startRecording, UNNotificationDefaultActionIdentifier:
                env?.startDetectedMeeting()
                WindowOpener.shared.open(WindowID.hub)
            default:
                env?.dismissDetectedCall()
            }
        }
    }
}

/// Opens SwiftUI `Window` scenes from AppKit code paths (delegate callbacks, menu bar).
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private var opener: ((String) -> Void)?

    /// Installed by the first SwiftUI view that appears (see `WindowOpenerBinder`).
    func register(_ open: @escaping (String) -> Void) {
        opener = open
    }

    func open(_ id: String, attempt: Int = 0) {
        NSApp.activate(ignoringOtherApps: true)
        if let opener {
            opener(id)
            return
        }
        // Scenes may not have rendered yet right after launch; retry briefly.
        guard attempt < 20 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.open(id, attempt: attempt + 1)
        }
    }
}

/// Invisible view that captures `openWindow` for `WindowOpener`.
struct WindowOpenerBinder: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                WindowOpener.shared.register { id in openWindow(id: id) }
            }
    }
}
