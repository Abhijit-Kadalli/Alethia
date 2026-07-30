import AppKit
import SwiftUI

/// Floating waveform panel shown while dictation is active.
@MainActor
public final class DictationOverlayController: ObservableObject {
    @Published public var level: Float = 0
    @Published public var isVisible = false

    private var panel: NSPanel?

    public init() {}

    public func show() {
        isVisible = true
        if panel == nil {
            let root = NSHostingController(rootView: DictationOverlayView(controller: self))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 72),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = root
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        positionCentered()
        panel?.orderFrontRegardless()
    }

    public func hide() {
        isVisible = false
        panel?.orderOut(nil)
        level = 0
    }

    public func updateLevel(_ rms: Float) {
        level = min(max(rms * 8, 0), 1)
    }

    private func positionCentered() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 48
        )
        panel.setFrameOrigin(origin)
    }
}

struct DictationOverlayView: View {
    @ObservedObject var controller: DictationOverlayController

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.red.opacity(0.85))
                .frame(width: 10, height: 10)
            Text("Dictating")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            WaveformBars(level: controller.level)
                .frame(width: 120, height: 28)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(8)
    }
}

struct WaveformBars: View {
    var level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<12, id: \.self) { idx in
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 4, height: barHeight(idx))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func barHeight(_ idx: Int) -> CGFloat {
        let base: CGFloat = 6
        let phase = abs(sin(Double(idx) * 0.7 + Double(level) * 6))
        return base + CGFloat(level) * 22 * CGFloat(phase)
    }
}
