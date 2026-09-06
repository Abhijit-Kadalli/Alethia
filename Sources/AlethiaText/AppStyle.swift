import Foundation

/// Target-app writing style used by dictation formatting and polish prompts.
public enum AppStyle: String, Codable, Sendable, CaseIterable {
    case standard
    case chat
    case email
    case code
    case terminal
    case search
    case notes

    /// Map a macOS bundle identifier to a style. Unknown → `.standard`.
    public static func infer(bundleID: String?) -> AppStyle {
        AppStyleResolver.style(forBundleID: bundleID)
    }

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .chat: return "Chat"
        case .email: return "Email"
        case .code: return "Code"
        case .terminal: return "Terminal"
        case .search: return "Search"
        case .notes: return "Notes"
        }
    }
}

/// Maps a macOS bundle identifier to an `AppStyle`.
public enum AppStyleResolver: Sendable {
    /// Returns a style for `id`, or `.standard` when the bundle is unknown or nil.
    public static func style(forBundleID id: String?) -> AppStyle {
        guard let raw = id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .standard
        }
        let bundle = raw.lowercased()
        if isBrowser(bundle) { return .standard }
        if let mapped = exact[bundle] { return mapped }
        if bundle.hasPrefix("com.jetbrains.") { return .code }
        if bundle.hasPrefix("com.intellij.") { return .code }
        if bundle.hasPrefix("com.google.android.") && bundle.contains("studio") { return .code }

        if let last = bundle.split(separator: ".").last.map(String.init), let mapped = lastComponent[last] {
            return mapped
        }

        if containsAny(bundle, ["slack", "discord", "whatsapp", "telegram", "signal", "teams", "zoom"]) {
            if bundle.contains("outlook") { return .email }
            return .chat
        }
        if containsAny(bundle, ["outlook", "spark", "airmail", "mimestream", "superhuman"]) {
            return .email
        }
        if bundle.hasSuffix(".mail") || bundle.contains("apple.mail") { return .email }
        if containsAny(bundle, ["vscode", "xcode", "zed", "sublime", "androidstudio", "android.studio"]) {
            return .code
        }
        if bundle.contains("todesktop.230313mzl4w4u92") { return .code }
        if containsAny(bundle, ["iterm", "alacritty", "ghostty", "wezterm", "warp", "kitty"]) {
            return .terminal
        }
        if bundle.contains("apple.terminal") { return .terminal }
        if containsAny(bundle, ["spotlight", "alfred", "raycast"]) { return .search }
        if containsAny(bundle, ["obsidian", "bear", "notion", "craft", "logseq", "apple.notes"]) {
            return .notes
        }
        return .standard
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains(where: { haystack.contains($0) })
    }

    private static func isBrowser(_ id: String) -> Bool {
        containsAny(id, ["chrome", "safari", "firefox", "brave.browser", "edgemac", "opera", "vivaldi"])
            && !id.contains("mail")
    }

    private static let exact: [String: AppStyle] = [
        "com.tinyspeck.slackmacgap": .chat,
        "com.slack.slack": .chat,
        "com.hnc.discord": .chat,
        "com.discord.discord": .chat,
        "com.apple.mobilesms": .chat,
        "com.apple.ichat": .chat,
        "com.apple.messages": .chat,
        "net.whatsapp.whatsapp": .chat,
        "net.whatsapp.whatsappdesktop": .chat,
        "ru.keepcoder.telegram": .chat,
        "org.telegram.desktop": .chat,
        "org.whispersystems.signal-desktop": .chat,
        "org.signal.signal": .chat,
        "com.microsoft.teams2": .chat,
        "com.microsoft.teams": .chat,
        "com.microsoft.teamsonmac": .chat,
        "us.zoom.xos": .chat,
        "zoom.us": .chat,
        "com.apple.mail": .email,
        "com.microsoft.outlook": .email,
        "com.microsoft.outlookformac": .email,
        "com.readdle.spark": .email,
        "com.readdle.smartemail": .email,
        "it.bloop.airmail2": .email,
        "it.bloop.airmail": .email,
        "com.mimestream.mimestream": .email,
        "com.superhuman.mail": .email,
        "com.superhuman.electron": .email,
        "com.apple.dt.xcode": .code,
        "com.microsoft.vscode": .code,
        "com.microsoft.vscodeinsiders": .code,
        "com.todesktop.230313mzl4w4u92": .code,
        "dev.zed.zed": .code,
        "dev.zed.zed-preview": .code,
        "com.sublimetext.4": .code,
        "com.sublimetext.3": .code,
        "com.panic.nova": .code,
        "com.google.android.studio": .code,
        "com.google.androidstudio": .code,
        "com.apple.terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        "dev.warp.warp-stable": .terminal,
        "dev.warp.warp": .terminal,
        "com.mitchellh.ghostty": .terminal,
        "org.alacritty": .terminal,
        "io.alacritty": .terminal,
        "net.kovidgoyal.kitty": .terminal,
        "com.github.wez.wezterm": .terminal,
        "com.apple.spotlight": .search,
        "com.runningwithcrayons.alfred": .search,
        "com.raycast.macos": .search,
        "com.apple.notes": .notes,
        "md.obsidian": .notes,
        "net.shinyfrog.bear": .notes,
        "com.bear-writer": .notes,
        "com.apple.textedit": .notes,
        "com.apple.iwork.pages": .notes,
        "com.microsoft.word": .notes,
        "notion.id": .notes,
        "com.lukilabs.craft": .notes,
        "com.logseq.logseq": .notes,
        "com.readdle.smartemail-mac": .email,
    ]

    private static let lastComponent: [String: AppStyle] = [
        "slackmacgap": .chat,
        "slack": .chat,
        "discord": .chat,
        "mobilesms": .chat,
        "whatsapp": .chat,
        "telegram": .chat,
        "signal": .chat,
        "teams2": .chat,
        "teams": .chat,
        "mail": .email,
        "outlook": .email,
        "spark": .email,
        "airmail2": .email,
        "mimestream": .email,
        "xcode": .code,
        "vscode": .code,
        "vscodeinsiders": .code,
        "zed": .code,
        "nova": .code,
        "terminal": .terminal,
        "iterm2": .terminal,
        "ghostty": .terminal,
        "alacritty": .terminal,
        "kitty": .terminal,
        "wezterm": .terminal,
        "spotlight": .search,
        "alfred": .search,
        "notes": .notes,
        "obsidian": .notes,
        "bear": .notes,
        "craft": .notes,
        "logseq": .notes,
    ]
}
