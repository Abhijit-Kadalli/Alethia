#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import AlethiaCore

/// The app and text field that will receive dictated text.
public struct InsertionTarget: Sendable, Equatable {
    public var bundleID: String?
    public var appName: String?
    public var processID: pid_t?
    /// Accessibility role of the focused element (`AXTextArea`, `AXTextField`, `AXWebArea`, …).
    public var role: String?
    public var isSecureField: Bool
    /// Up to 200 characters before the caret, when the field exposes its value.
    public var precedingText: String?
    /// True when an editable text element is focused.
    public var hasEditableFocus: Bool

    public init(bundleID: String? = nil, appName: String? = nil, processID: pid_t? = nil, role: String? = nil,
                isSecureField: Bool = false, precedingText: String? = nil, hasEditableFocus: Bool = false) {
        self.bundleID = bundleID
        self.appName = appName
        self.processID = processID
        self.role = role
        self.isSecureField = isSecureField
        self.precedingText = precedingText
        self.hasEditableFocus = hasEditableFocus
    }
}

/// Puts text into whatever has keyboard focus.
///
/// Strategy: Accessibility (`AXSelectedText`) when the element accepts it and the write is
/// verifiable; otherwise ⌘V with the pasteboard saved and restored; otherwise synthesized
/// Unicode key events. The last resort leaves the text on the clipboard.
@MainActor
public final class TextInserter {
    /// `kAXSecureTextFieldRole` is a CFSTR macro and is not imported into Swift.
    private let secureTextFieldRole = "AXSecureTextField"
    public var pasteSettleDelay: Duration = .milliseconds(180)
    private let log = Log("Insert")

    public init() {}

    // MARK: Target inspection

    public func currentTarget() -> InsertionTarget {
        var target = InsertionTarget()
        if let app = NSWorkspace.shared.frontmostApplication {
            target.bundleID = app.bundleIdentifier
            target.appName = app.localizedName
            target.processID = app.processIdentifier
        }
        guard let element = focusedElement() else { return target }
        target.role = stringAttribute(element, kAXRoleAttribute)
        target.isSecureField = target.role == secureTextFieldRole
        let editableRoles: Set<String> = [
            kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole,
            secureTextFieldRole, "AXWebArea", "AXSearchField",
        ]
        var settable = DarwinBoolean(false)
        let canSetSelected = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        target.hasEditableFocus = canSetSelected || editableRoles.contains(target.role ?? "")
        if !target.isSecureField, let value = stringAttribute(element, kAXValueAttribute), let range = selectedRange(element) {
            let location = min(max(range.location, 0), value.utf16.count)
            let prefix = String(utf16CodeUnits: Array(value.utf16.prefix(location)), count: location)
            target.precedingText = String(prefix.suffix(200))
        }
        return target
    }

    // MARK: Insertion

    /// Inserts `text` at the caret and reports how.
    public func insert(_ text: String, allowAccessibility: Bool = true, allowPaste: Bool = true) async -> InsertionMethod {
        guard !text.isEmpty else { return .accessibility }
        // Re-check on every path: focus can move to a password field after dictation started.
        if focusedIsSecureField() { return .blockedSecureField }
        if allowAccessibility, insertViaAccessibility(text) {
            return .accessibility
        }
        if focusedIsSecureField() { return .blockedSecureField }
        if allowPaste, await insertViaPaste(text) {
            return .paste
        }
        if focusedIsSecureField() { return .blockedSecureField }
        if typeUnicode(text) {
            return .keystrokes
        }
        if focusedIsSecureField() { return .blockedSecureField }
        writeConcealedClipboard(text)
        return .clipboardOnly
    }

    /// Replace the `previous` text that was just inserted with `replacement`.
    public func replaceLastInsertion(previous: String, with replacement: String) async -> InsertionMethod {
        if focusedIsSecureField() { return .blockedSecureField }
        if replaceViaAccessibility(previous: previous, with: replacement) {
            return .accessibility
        }
        if focusedIsSecureField() { return .blockedSecureField }
        // HID delete removes a user-perceived character (grapheme), not a UTF-16 unit.
        guard sendBackspaces(count: TextMetrics.deletionKeystrokes(for: previous)) else {
            return .blockedSecureField
        }
        try? await Task.sleep(for: .milliseconds(40))
        if focusedIsSecureField() { return .blockedSecureField }
        let method = await insert(replacement)
        if method == .clipboardOnly {
            _ = await insert(previous)
        }
        return method
    }

    private func focusedIsSecureField() -> Bool {
        currentTarget().isSecureField
    }

    // MARK: Accessibility path

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let element = focusedElement(), !isSecureElement(element) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let before = stringAttribute(element, kAXValueAttribute)
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard result == .success else { return false }
        // Some apps (Electron, Chromium) accept the write but ignore it. Verify when possible.
        if let before, let after = stringAttribute(element, kAXValueAttribute) {
            guard after != before, after.contains(text) || after.utf16.count >= before.utf16.count + text.utf16.count else {
                log.debug("AX write not reflected in value for role \(stringAttribute(element, kAXRoleAttribute) ?? "?")")
                return false
            }
        } else if before == nil {
            // Cannot verify; only trust native text roles.
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            guard role == kAXTextAreaRole || role == kAXTextFieldRole else { return false }
        }
        return true
    }

    private func replaceViaAccessibility(previous: String, with replacement: String) -> Bool {
        guard let element = focusedElement(), !isSecureElement(element),
              let value = stringAttribute(element, kAXValueAttribute),
              let range = selectedRange(element) else { return false }
        let caret = range.location + range.length
        let length = TextMetrics.utf16Length(of: previous)
        guard caret >= length else { return false }
        let start = caret - length
        let utf16 = Array(value.utf16)
        guard start + length <= utf16.count,
              String(utf16CodeUnits: Array(utf16[start..<(start + length)]), count: length) == previous else { return false }
        var target = CFRange(location: start, length: length)
        guard let axRange = AXValueCreate(.cfRange, &target),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
            return false
        }
        let after = stringAttribute(element, kAXValueAttribute)
        return after != nil && after != value
    }

    private func isSecureElement(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute) == secureTextFieldRole
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        return value as? String
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: Paste path

    private func insertViaPaste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        guard writeConcealedClipboard(text) else { return false }
        let ourChange = pasteboard.changeCount

        guard sendKey(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            saved.restore(to: pasteboard)
            return false
        }
        try? await Task.sleep(for: pasteSettleDelay)
        if pasteboard.changeCount == ourChange {
            saved.restore(to: pasteboard)
            return false
        }
        return true
    }

    // MARK: Key events

    @discardableResult
    private func writeConcealedClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Clipboard managers honour this marker and skip transient content.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        return pasteboard.writeObjects([item])
    }

    private func sendKey(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Returns false if focus moved to a password field mid-delete.
    @discardableResult
    private func sendBackspaces(count: Int) -> Bool {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return true }
        for _ in 0..<count {
            if focusedIsSecureField() { return false }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(1500)
        }
        return true
    }

    private func typeUnicode(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 20, units.count)
            var chunk = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
            usleep(2000)
        }
        return true
    }
}

/// Everything on the pasteboard, so it can be put back after a synthetic ⌘V.
private struct PasteboardSnapshot {
    private var items: [[NSPasteboard.PasteboardType: Data]] = []

    init(_ pasteboard: NSPasteboard) {
        for item in pasteboard.pasteboardItems ?? [] {
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    payload[type] = data
                }
            }
            if !payload.isEmpty {
                items.append(payload)
            }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
#endif
