#if os(macOS)
import AppKit
import SwiftUI
import AlethiaCore

@MainActor
final class CorrectionPanelModel: ObservableObject {
    @Published var text: String = ""
    @Published var original: String = ""
    @Published var secondsLeft: Int = 0
    @Published var isEditing = false
    var onApply: ((String) -> Void)?
    var onDismiss: (() -> Void)?
}

/// Shows the just-inserted text for a few seconds so it can be fixed in place. Becomes key
/// without activating Alethia, so the target app keeps its window focus.
@MainActor
public final class CorrectionPanelController {
    private let model = CorrectionPanelModel()
    private var panel: NSPanel?
    private var countdown: Task<Void, Never>?

    public init() {}

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// - Parameters:
    ///   - text: what was inserted
    ///   - seconds: auto-dismiss delay; editing pauses it
    ///   - onApply: called with the edited text when the user confirms a change
    public func present(text: String, seconds: Double, onApply: @escaping (String) -> Void) {
        countdown?.cancel()
        model.text = text
        model.original = text
        model.isEditing = false
        model.secondsLeft = Int(seconds.rounded(.up))
        model.onApply = { [weak self] edited in
            self?.dismiss()
            if edited != text {
                onApply(edited)
            }
        }
        model.onDismiss = { [weak self] in self?.dismiss() }

        let panel = ensurePanel()
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        countdown = Task { [weak self] in
            guard let self else { return }
            while self.model.secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if self.model.isEditing { continue }
                self.model.secondsLeft -= 1
            }
            if !self.model.isEditing {
                self.dismiss()
            }
        }
    }

    public func dismiss() {
        countdown?.cancel()
        countdown = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let hosting = NSHostingView(rootView: CorrectionPanelView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 140))
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        (contentView as? NSHostingView<CorrectionPanelView>)?.rootView.model.onDismiss?()
    }
}

struct CorrectionPanelView: View {
    @ObservedObject var model: CorrectionPanelModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Inserted", systemImage: "text.cursor")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.isEditing {
                    Text("Closes in \(model.secondsLeft)s · click to fix")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            TextEditor(text: $model.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 44, maxHeight: 120)
                .focused($focused)
                .onChange(of: model.text) { _, new in
                    if new != model.original { model.isEditing = true }
                }
                .onTapGesture { model.isEditing = true; focused = true }
            HStack {
                Text("Edits teach Alethia your vocabulary.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Dismiss") { model.onDismiss?() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply Fix") { model.onApply?(model.text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.text == model.original || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial)
    }
}
#endif
