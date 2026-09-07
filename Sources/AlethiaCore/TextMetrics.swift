import Foundation

/// Shared length rules for insertion and correction.
public enum TextMetrics {
    /// HID/backspace count: one key event per extended grapheme cluster.
    /// Using UTF-16 length here over-deletes emoji and composed characters.
    public static func deletionKeystrokes(for text: String) -> Int {
        text.count
    }

    /// Accessibility `AXSelectedTextRange` length.
    public static func utf16Length(of text: String) -> Int {
        text.utf16.count
    }
}
