#if os(macOS)
import AppKit
import Combine
import Foundation
import AlethiaAudio
import AlethiaCore
import AlethiaKnowledge
import AlethiaSpeech
import AlethiaText

/// Push-to-talk / toggle dictation: hotkey → microphone → live recognizer → formatter →
/// insertion into the focused app → correction popover → history + learned dictionary.
@MainActor
public final class DictationController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case listening
        case processing
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastError: String?
    @Published public private(set) var hotkeyActive = false
    /// Optional LLM polish; nil disables the pass.
    public var polisher: DictationPolisher?

    private let store: KnowledgeStore
    private let speech: any SpeechEngineProtocol
    private let settings: SettingsStore
    private let hotkey: HotkeyMonitor
    private let overlay = DictationOverlayController()
    private let correction = CorrectionPanelController()
    private let inserter = TextInserter()
    private let formatter = DictationFormatter()
    private let learner = CorrectionLearner()
    private let log = Log("Dictation")

    private var capture: DictationAudioCapture?
    private var live: LiveTranscriber?
    private var liveTask: Task<Void, Never>?
    private var meter = AudioLevelMeter()
    private var target: InsertionTarget?
    private var startedAt: Date?
    private var pendingCorrectionDictationID: UUID?

    public init(store: KnowledgeStore, speech: any SpeechEngineProtocol, settings: SettingsStore) {
        self.store = store
        self.speech = speech
        self.settings = settings
        self.hotkey = HotkeyMonitor(hotkey: settings.load().dictation.hotkey)
        hotkey.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: Hotkey lifecycle

    /// Installs the global hotkey. Requires Accessibility (Input Monitoring) permission.
    public func activateHotkey() throws {
        guard !hotkey.isRunning else { return }
        try hotkey.start()
        hotkeyActive = true
    }

    public func deactivateHotkey() {
        hotkey.stop()
        hotkeyActive = false
    }

    /// Re-read settings (hotkey binding may have changed).
    public func settingsDidChange() {
        let dictation = settings.load().dictation
        if hotkey.hotkey != dictation.hotkey {
            hotkey.hotkey = dictation.hotkey
        }
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        let activation = settings.load().dictation.activation
        switch (event, activation) {
        case (.pressed, .holdToTalk):
            Task { await begin() }
        case (.released(let heldMs), .holdToTalk):
            // A tap shorter than this is almost always accidental (or a toggle attempt).
            if heldMs < 250 {
                Task { await cancel(reason: nil) }
            } else {
                Task { await finish() }
            }
        case (.pressed, .toggle):
            break
        case (.released, .toggle):
            if state == .listening {
                Task { await finish() }
            } else if state == .idle {
                Task { await begin() }
            }
        case (.cancelled, _):
            Task { await cancel(reason: nil) }
        }
    }

    /// Programmatic start (menu bar button).
    public func toggle() {
        if state == .listening {
            Task { await finish() }
        } else if state == .idle {
            Task { await begin() }
        }
    }

    // MARK: Session

    private func begin() async {
        guard state == .idle else { return }
        let dictation = settings.load().dictation
        lastError = nil
        correction.dismiss()

        let target = inserter.currentTarget()
        if target.isSecureField {
            showError("Dictation is off in password fields.")
            return
        }
        self.target = target

        do {
            try await speech.prepare()
        } catch {
            showError(error.localizedDescription)
            return
        }

        let capture = DictationAudioCapture()
        let live: LiveTranscriber
        do {
            live = try await speech.startLiveTranscription()
            try capture.start()
        } catch {
            showError((error as? AlethiaError)?.errorDescription ?? error.localizedDescription)
            return
        }
        capture.onFrames = { [weak self, live] frames in
            live.feed(frames)
            let rms = AudioMixer.rms(frames)
            Task { @MainActor [weak self] in
                guard let self, self.state == .listening else { return }
                self.overlay.update(level: self.meter.update(rms: rms))
            }
        }
        self.capture = capture
        self.live = live
        startedAt = Date()
        state = .listening
        overlay.show(phase: .listening)
        if dictation.playSounds { DictationSounds.start() }
        liveTask = Task { [weak self] in
            for await update in live.updates {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.overlay.update(partialText: update.text) }
            }
        }
        log.info("listening → \(target.appName ?? "unknown app")")
    }

    private func finish() async {
        guard state == .listening, let capture, let live else { return }
        state = .processing
        liveTask?.cancel()
        let dictation = settings.load().dictation
        if dictation.playSounds { DictationSounds.stop() }
        overlay.show(phase: .processing)

        let (samples, durationMs) = capture.stop()
        self.capture = nil
        self.live = nil

        guard durationMs >= 300 else {
            live.cancel()
            overlay.hide()
            state = .idle
            return
        }

        let segment: TranscriptSegment
        do {
            segment = try await live.finish()
        } catch {
            live.cancel()
            showError((error as? AlethiaError)?.errorDescription ?? error.localizedDescription)
            state = .idle
            return
        }
        _ = samples

        let raw = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            overlay.flash(.error("Didn't catch that"), for: .seconds(1.2))
            state = .idle
            return
        }

        let target = self.target ?? inserter.currentTarget()
        let style = dictation.appAwareStyle ? AppStyleResolver.style(forBundleID: target.bundleID) : .standard
        let context = FormattingContext(
            style: style,
            options: FormattingOptions(settings: dictation),
            dictionary: (try? store.dictionaryEntries()) ?? [],
            snippets: (try? store.snippets()) ?? [],
            language: dictation.language,
            precedingText: target.precedingText
        )
        let formatted = formatter.format(raw, context: context)
        var finalText = formatted.text
        var stages = formatted.appliedStages

        if formatted.wasScratched || finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlay.flash(.error("Scratched"), for: .seconds(1))
            state = .idle
            return
        }

        if let polisher, settings.load().languageModel.polishDictation {
            if let polished = await polisher.polish(finalText, style: style) {
                finalText = polished
                stages.append("llm-polish")
            }
        }

        let method = await inserter.insert(finalText)
        overlay.flash(.inserted(finalText), for: .seconds(1.4))

        let record = Dictation(
            rawText: raw,
            finalText: finalText,
            targetBundleID: target.bundleID,
            targetAppName: target.appName,
            durationMs: durationMs,
            insertion: method,
            appliedStages: stages
        )
        if dictation.keepHistory {
            try? store.saveDictation(record)
        }
        if !formatted.firedDictionaryEntryIDs.isEmpty {
            try? store.recordDictionaryUse(ids: formatted.firedDictionaryEntryIDs)
        }
        if !formatted.expandedSnippetIDs.isEmpty {
            try? store.recordSnippetUse(ids: formatted.expandedSnippetIDs)
        }
        state = .idle

        if dictation.showCorrectionPopover, method != .clipboardOnly {
            pendingCorrectionDictationID = record.id
            correction.present(text: finalText, seconds: dictation.correctionPopoverSeconds) { [weak self] edited in
                Task { @MainActor in
                    await self?.applyCorrection(dictationID: record.id, original: finalText, edited: edited)
                }
            }
        }
        log.info("inserted \(finalText.count) chars via \(method.rawValue) in \(target.appName ?? "?")")
    }

    private func cancel(reason: String?) async {
        guard state == .listening else { return }
        liveTask?.cancel()
        live?.cancel()
        _ = capture?.stop()
        capture = nil
        live = nil
        state = .idle
        if let reason {
            overlay.flash(.error(reason), for: .seconds(1))
        } else {
            overlay.hide()
        }
    }

    // MARK: Corrections

    /// Replace the just-inserted text with the user's edit, and learn from the difference.
    public func applyCorrection(dictationID: UUID, original: String, edited: String) async {
        let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        _ = await inserter.replaceLastInsertion(previous: original, with: trimmed)
        try? store.updateDictationEdit(id: dictationID, editedText: trimmed)
        learn(inserted: original, edited: trimmed)
    }

    /// Edits made later in the history view also teach the dictionary.
    public func learn(inserted: String, edited: String) {
        for suggestion in learner.suggestions(inserted: inserted, edited: edited) {
            let entry = DictionaryEntry(spoken: suggestion.spoken, written: suggestion.written, origin: .learned)
            try? store.upsertDictionaryEntry(entry)
            log.info("learned \"\(suggestion.spoken)\" → \"\(suggestion.written)\"")
        }
    }

    private func showError(_ message: String) {
        lastError = message
        if settings.load().dictation.playSounds { DictationSounds.error() }
        overlay.flash(.error(message), for: .seconds(2))
        state = .idle
        log.warning(message)
    }
}
#endif
