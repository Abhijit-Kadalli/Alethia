#if os(macOS)
import AppKit

/// Short system sounds for start / stop / error, kept quiet so they never clash with a call.
@MainActor
enum DictationSounds {
    static func start() { play("Tink", volume: 0.35) }
    static func stop() { play("Pop", volume: 0.35) }
    static func error() { play("Basso", volume: 0.4) }

    private static func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = volume
        sound.play()
    }
}
#endif
