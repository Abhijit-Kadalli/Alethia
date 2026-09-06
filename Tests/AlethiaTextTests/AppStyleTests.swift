import XCTest
import AlethiaCore
@testable import AlethiaText

final class AppStyleTests: XCTestCase {
    func testKnownBundleIDs() {
        XCTAssertEqual(AppStyleResolver.style(forBundleID: nil), .standard)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: ""), .standard)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "unknown.foo.bar"), .standard)

        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.hnc.Discord"), .chat)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.apple.MobileSMS"), .chat)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "net.whatsapp.WhatsApp"), .chat)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "ru.keepcoder.Telegram"), .chat)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "org.whispersystems.signal-desktop"), .chat)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.microsoft.teams2"), .chat)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "us.zoom.xos"), .chat)

        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.microsoft.Outlook"), .email)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.readdle.Spark"), .email)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "it.bloop.airmail2"), .email)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.mimestream.Mimestream"), .email)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.superhuman.mail"), .email)

        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.todesktop.230313mzl4w4u92"), .code)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "dev.zed.Zed"), .code)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.jetbrains.intellij"), .code)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.jetbrains.WebStorm"), .code)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.sublimetext.4"), .code)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.panic.Nova"), .code)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.google.android.studio"), .code)

        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.googlecode.iterm2"), .terminal)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "dev.warp.Warp-Stable"), .terminal)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "org.alacritty"), .terminal)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "net.kovidgoyal.kitty"), .terminal)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.github.wez.wezterm"), .terminal)

        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.apple.Spotlight"), .search)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.runningwithcrayons.Alfred"), .search)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.raycast.macos"), .search)

        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.apple.Notes"), .notes)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "md.obsidian"), .notes)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "net.shinyfrog.bear"), .notes)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "notion.id"), .notes)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.lukilabs.craft"), .notes)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.logseq.logseq"), .notes)
    }

    func testBrowserStaysStandard() {
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.google.Chrome"), .standard)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "com.apple.Safari"), .standard)
        XCTAssertEqual(AppStyleResolver.style(forBundleID: "org.mozilla.firefox"), .standard)
    }

    func testCaseIterableCount() {
        XCTAssertEqual(AppStyle.allCases.count, 7)
    }
}
