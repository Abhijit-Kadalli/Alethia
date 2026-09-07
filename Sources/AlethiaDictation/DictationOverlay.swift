#if os(macOS)
import AppKit
import SwiftUI
import AlethiaCore

/// What the floating dictation pill is showing.
public enum DictationPhase: Equatable, Sendable {
    case hidden
    case listening
    case processing
    case inserted(String)
    case copied(String)
    case error(String)
}

@MainActor
public final class DictationOverlayModel: ObservableObject {
    @Published public var phase: DictationPhase = .hidden
    @Published public var level: Float = 0
    @Published public var partialText: String = ""
    @Published public var hotkeySymbol: String = "🌐"
    @Published public var isToggleMode = false

    public init() {}
}

/// A borderless, non-activating panel anchored to the bottom of the active screen.
@MainActor
public final class DictationOverlayController {
    public let model = DictationOverlayModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    public init() {}

    public func show(phase: DictationPhase) {
        hideTask?.cancel()
        model.phase = phase
        if phase == .listening {
            model.partialText = ""
            model.level = 0
        }
        let panel = ensurePanel()
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    public func update(level: Float) {
        model.level = level
    }

    public func update(partialText: String) {
        model.partialText = partialText
    }

    public func flash(_ phase: DictationPhase, for duration: Duration) {
        show(phase: phase)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    public func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else {
            model.phase = .hidden
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                self.model.phase = .hidden
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: DictationOverlayView(model: model))
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 36)
        panel.setFrameOrigin(origin)
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct DictationOverlayView: View {
    @ObservedObject var model: DictationOverlayModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                indicator
                    .frame(width: 44, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 13))
                            .lineLimit(2)
                            .truncationMode(.head)
                            .foregroundStyle(.primary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 380)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
        .frame(width: 380, height: 92, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .listening:
            LevelBars(level: model.level)
        case .processing:
            ProgressView().controlSize(.small)
        case .inserted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
        case .copied:
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
        case .hidden:
            EmptyView()
        }
    }

    private var title: String {
        switch model.phase {
        case .listening:
            return model.isToggleMode ? "Listening · press \(model.hotkeySymbol) to finish" : "Listening · release \(model.hotkeySymbol) to insert"
        case .processing: return "Transcribing…"
        case .inserted: return "Inserted"
        case .copied: return "Copied — paste with ⌘V"
        case .error: return "Dictation failed"
        case .hidden: return ""
        }
    }

    private var detail: String {
        switch model.phase {
        case .listening, .processing: return model.partialText
        case .inserted(let text), .copied(let text): return text
        case .error(let message): return message
        case .hidden: return ""
        }
    }
}

/// Animated bars driven by the microphone level.
struct LevelBars: View {
    var level: Float
    private let bars = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4, height: height(for: index))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let weights: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]
        let base: CGFloat = 5
        let max: CGFloat = 26
        return base + (max - base) * CGFloat(min(level, 1)) * weights[index % weights.count]
    }
}
#endif
