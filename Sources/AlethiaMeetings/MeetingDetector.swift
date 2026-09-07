#if os(macOS)
import AppKit
import Foundation
import AlethiaAudio
import AlethiaCore

/// Notices when a call probably started: another app opened the microphone and a known
/// conferencing app is running (or the mic stays open for a while regardless).
@MainActor
public final class MeetingDetector {
    public struct Detection: Sendable, Equatable {
        public var appName: String?
        public var bundleID: String?
        public var detectedAt: Date
    }

    public static let conferencingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.google.Chrome": "Google Meet",
        "com.apple.Safari": "Browser call",
        "company.thebrowser.Browser": "Browser call",
        "com.brave.Browser": "Browser call",
        "org.mozilla.firefox": "Browser call",
        "com.tinyspeck.slackmacgap": "Slack huddle",
        "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.ringcentral.RingCentral": "RingCentral",
        "com.gotomeeting.GoToMeeting": "GoToMeeting",
        "com.skype.skype": "Skype",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.loom.desktop": "Loom",
    ]

    /// Fires once per detected call while enabled and not suppressed.
    public var onMeetingDetected: ((Detection) -> Void)?
    /// Fires when the microphone has been idle for `endGraceSeconds` after a detection.
    public var onMeetingProbablyEnded: (() -> Void)?

    /// Delay before a mic-in-use signal counts as a call (filters quick voice memos, Siri).
    public var confirmSeconds: TimeInterval = 4
    public var endGraceSeconds: TimeInterval = 20
    /// While true (Alethia itself is recording) detections are ignored.
    public var suppressed = false
    /// After the user dismisses an offer, ignore further detections until the mic goes idle.
    private var ignoreUntilIdle = false

    private let monitor = MicrophoneActivityMonitor()
    private var pendingConfirm: Task<Void, Never>?
    private var pendingEnd: Task<Void, Never>?
    private var active: Detection?
    private let log = Log("Detector")

    public init() {}

    public var isRunning: Bool { running }
    private var running = false

    public func start() {
        guard !running else { return }
        running = true
        monitor.onChange = { [weak self] inUse in
            Task { @MainActor in
                self?.microphoneChanged(inUse: inUse)
            }
        }
        monitor.start()
        if monitor.isMicrophoneInUse {
            microphoneChanged(inUse: true)
        }
    }

    public func stop() {
        running = false
        monitor.stop()
        pendingConfirm?.cancel()
        pendingEnd?.cancel()
        active = nil
    }

    /// Call when the user starts or stops a recording so the detector does not react to our own capture.
    public func setRecording(_ recording: Bool) {
        suppressed = recording
        if recording {
            pendingConfirm?.cancel()
            pendingEnd?.cancel()
            active = nil
            ignoreUntilIdle = false
        }
    }

    /// User declined this detection. Do not offer again until the microphone is released.
    public func dismissActiveDetection() {
        pendingConfirm?.cancel()
        pendingConfirm = nil
        pendingEnd?.cancel()
        pendingEnd = nil
        active = nil
        ignoreUntilIdle = true
    }

    private func microphoneChanged(inUse: Bool) {
        guard running, !suppressed else { return }
        if inUse {
            if ignoreUntilIdle { return }
            pendingEnd?.cancel()
            guard active == nil, pendingConfirm == nil else { return }
            pendingConfirm = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.confirmSeconds ?? 4))
                guard let self, !Task.isCancelled else { return }
                self.pendingConfirm = nil
                guard self.running, !self.suppressed, self.monitor.isMicrophoneInUse else { return }
                let app = Self.runningConferencingApp()
                let detection = Detection(appName: app?.name, bundleID: app?.bundleID, detectedAt: Date())
                self.active = detection
                self.log.info("call detected (\(app?.name ?? "unknown app"))")
                self.onMeetingDetected?(detection)
            }
        } else {
            ignoreUntilIdle = false
            pendingConfirm?.cancel()
            pendingConfirm = nil
            guard active != nil else { return }
            pendingEnd?.cancel()
            pendingEnd = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.endGraceSeconds ?? 20))
                guard let self, !Task.isCancelled, !self.monitor.isMicrophoneInUse else { return }
                self.active = nil
                self.onMeetingProbablyEnded?()
            }
        }
    }

    public static func runningConferencingApp() -> (name: String, bundleID: String)? {
        let running = NSWorkspace.shared.runningApplications
        // Dedicated clients beat browsers.
        let dedicated = running.first { app in
            guard let id = app.bundleIdentifier, let _ = conferencingApps[id] else { return false }
            return !id.contains("Chrome") && !id.contains("Safari") && !id.contains("Browser") && !id.contains("firefox")
        }
        if let dedicated, let id = dedicated.bundleIdentifier, let name = conferencingApps[id] {
            return (name, id)
        }
        if let browser = running.first(where: { app in
            guard let id = app.bundleIdentifier else { return false }
            return conferencingApps[id] != nil && app.isActive
        }), let id = browser.bundleIdentifier, let name = conferencingApps[id] {
            return (name, id)
        }
        return nil
    }
}
#endif
