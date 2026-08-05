import AVFoundation
import Combine
import Foundation

/// Plays archived meeting WAV and seeks to transcript timestamps (ms from recording start).
@MainActor
final class MeetingAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentMs = 0
    @Published private(set) var durationMs = 0
    @Published private(set) var hasAudio = false
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var tick: Timer?
    private var loadedURL: URL?

    func load(url: URL?) {
        stop()
        loadedURL = nil
        hasAudio = false
        durationMs = 0
        currentMs = 0
        errorMessage = nil
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Recording file missing"
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            loadedURL = url
            hasAudio = true
            durationMs = Int(p.duration * 1000)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func seek(toMs ms: Int, andPlay: Bool = true) {
        guard let player else { return }
        let clamped = max(0, min(Double(ms) / 1000.0, player.duration - 0.01))
        player.currentTime = max(clamped, 0)
        currentMs = Int(player.currentTime * 1000)
        if andPlay {
            play()
        }
    }

    func toggle() {
        guard player != nil else { return }
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTick()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTick()
        syncTime()
    }

    func stop() {
        stopTick()
        player?.stop()
        player = nil
        isPlaying = false
        currentMs = 0
    }

    private func startTick() {
        stopTick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncTime()
            }
        }
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    private func syncTime() {
        guard let player else { return }
        currentMs = Int(player.currentTime * 1000)
        if !player.isPlaying {
            isPlaying = false
            stopTick()
        }
    }
}
