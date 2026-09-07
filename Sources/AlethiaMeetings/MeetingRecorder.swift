#if os(macOS)
import Combine
import Foundation
import AlethiaAudio
import AlethiaCore
import AlethiaKnowledge
import AlethiaSpeech

/// Records a meeting: audio capture → WAV + live transcript, then hands the finished
/// recording to `MeetingProcessor`.
@MainActor
public final class MeetingRecorder: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case recording(meetingID: UUID)
        case stopping
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var elapsedMs = 0
    @Published public private(set) var level: Float = 0
    @Published public private(set) var systemLevel: Float = 0
    @Published public private(set) var liveTranscript = LiveTranscriptUpdate()
    @Published public private(set) var warning: String?
    @Published public private(set) var capturingSystemAudio = false
    /// Meeting row being recorded (title/notes editable while it runs).
    @Published public private(set) var current: Meeting?
    /// Return a reason to refuse `start()`, e.g. while dictation is listening.
    public var beginBlockedReason: (() -> String?)?

    private let store: KnowledgeStore
    private let speech: any SpeechEngineProtocol
    private let processor: MeetingProcessor
    private let settings: SettingsStore
    private let paths: AppPaths
    private let calendar: CalendarService
    private let log = Log("Meetings")

    private var capture: MeetingAudioCapture?
    private var live: LiveTranscriber?
    private var liveTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var meter = AudioLevelMeter()
    private var systemMeter = AudioLevelMeter()

    public init(store: KnowledgeStore, speech: any SpeechEngineProtocol, processor: MeetingProcessor,
                settings: SettingsStore, paths: AppPaths, calendar: CalendarService) {
        self.store = store
        self.speech = speech
        self.processor = processor
        self.settings = settings
        self.paths = paths
        self.calendar = calendar
    }

    public var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    // MARK: Start / stop

    /// Starts a new meeting. `title` overrides calendar/detector suggestions.
    @discardableResult
    public func start(title: String? = nil, suggestedApp: String? = nil) async throws -> Meeting {
        guard phase == .idle else {
            if let current { return current }
            throw AlethiaError.invalidInput("A recording is already in progress.")
        }
        if let reason = beginBlockedReason?() {
            throw AlethiaError.invalidInput(reason)
        }
        try await PermissionGate().requireMicrophone()
        phase = .starting
        warning = nil
        liveTranscript = LiveTranscriptUpdate()
        elapsedMs = 0

        do {
            try await speech.prepare()
        } catch {
            phase = .idle
            throw error
        }

        let meetingSettings = settings.load().meetings
        var calendarContext: CalendarContext?
        if meetingSettings.useCalendar, calendar.authorizationState == .granted {
            calendarContext = calendar.currentEvent()
        }
        let resolvedTitle = title?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? calendarContext?.title
            ?? suggestedApp.map { "\($0) call" }
            ?? Self.defaultTitle(for: Date())

        var meeting = Meeting(
            title: resolvedTitle,
            source: meetingSettings.includeSystemAudio ? .microphoneAndSystem : .microphone,
            status: .recording,
            calendarEventID: calendarContext?.eventID,
            attendees: calendarContext?.attendees ?? []
        )
        meeting.audioPath = paths.relativeRecordingPath(for: meeting.id)

        let capture = MeetingAudioCapture()
        var live: LiveTranscriber?
        do {
            try paths.ensureDirectories()
            try store.saveMeeting(meeting)
            current = meeting
            if meetingSettings.liveTranscript {
                live = try await speech.startLiveTranscription(retainFullAudio: false)
            }
            capture.onChunk = { [weak self, live] chunk in
                live?.feed(chunk.samples)
                guard let self else { return }
                Task { @MainActor in
                    self.level = self.meter.update(rms: chunk.microphoneRMS)
                    self.systemLevel = self.systemMeter.update(rms: chunk.systemRMS)
                }
            }
            capture.onWarning = { [weak self] message in
                Task { @MainActor in self?.warning = message }
            }
            let withSystem = try await capture.start(to: paths.recordingURL(for: meeting.id), includeSystemAudio: meetingSettings.includeSystemAudio)
            capturingSystemAudio = withSystem
            if !withSystem {
                meeting.source = .microphone
                try? store.updateMeetingMetadata(meeting)
            }
        } catch {
            live?.cancel()
            try? store.deleteMeeting(id: meeting.id)
            phase = .idle
            throw error
        }

        self.capture = capture
        self.live = live
        self.current = meeting
        phase = .recording(meetingID: meeting.id)
        startTicker()
        if let live {
            liveTask = Task { [weak self] in
                for await update in live.updates {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.liveTranscript = update }
                }
            }
        }
        log.info("recording started \(meeting.id) system=\(capturingSystemAudio)")
        return meeting
    }

    /// Stops recording and starts background processing. Returns the meeting id.
    @discardableResult
    public func stop() async -> UUID? {
        guard case .recording(let meetingID) = phase, let capture else { return nil }
        phase = .stopping
        ticker?.cancel()
        let live = self.live
        self.live = nil

        // Flush remaining mixer hops into the live session, then wait one decode tick
        // so the provisional transcript includes the tail of the recording.
        let result = await capture.stop()
        self.capture = nil
        if live != nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        liveTask?.cancel()
        live?.cancel()

        var meeting = current ?? (try? store.meeting(id: meetingID)) ?? Meeting(id: meetingID, title: Self.defaultTitle(for: Date()))
        meeting.endedAt = result?.endedAt ?? Date()
        meeting.durationMs = result?.durationMs ?? elapsedMs
        meeting.status = .processing
        // Keep the live transcript visible while the accurate pass runs.
        meeting.utterances = Self.provisionalUtterances(from: liveTranscript, meetingID: meetingID)
        do {
            try store.saveMeeting(meeting)
        } catch {
            warning = "Couldn't save the meeting: \(error.localizedDescription)"
            log.error("stop persist failed: \(error.localizedDescription)")
            do {
                try store.updateStatus(meetingID: meetingID, status: .processing, error: nil)
            } catch {
                log.error("stop status retry failed: \(error.localizedDescription)")
            }
        }

        current = nil
        level = 0
        systemLevel = 0
        phase = .idle

        if let result {
            processor.enqueue(meetingID: meetingID, capture: result)
        } else {
            do {
                try store.updateStatus(meetingID: meetingID, status: .failed, error: "No audio was recorded.")
            } catch {
                warning = "Couldn't save the meeting: \(error.localizedDescription)"
                log.error("failed-status persist: \(error.localizedDescription)")
            }
        }
        return meetingID
    }

    /// Discards the current recording entirely.
    public func discard() async {
        guard case .recording(let meetingID) = phase, let capture else { return }
        phase = .stopping
        ticker?.cancel()
        liveTask?.cancel()
        live?.cancel()
        live = nil
        let result = await capture.stop()
        self.capture = nil
        if let url = result?.audioURL {
            try? FileManager.default.removeItem(at: url)
        }
        try? store.deleteMeeting(id: meetingID)
        current = nil
        level = 0
        systemLevel = 0
        phase = .idle
    }

    // MARK: Editing while recording

    public func updateTitle(_ title: String) {
        guard var meeting = current else { return }
        meeting.title = title
        current = meeting
        try? store.updateTitle(meetingID: meeting.id, title: title)
    }

    public func updateUserNotes(_ notes: String) {
        guard var meeting = current else { return }
        meeting.userNotes = notes
        current = meeting
        try? store.updateUserNotes(meetingID: meeting.id, notes: notes)
    }

    // MARK: Helpers

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let capture = self.capture else { return }
                self.elapsedMs = capture.durationMs
            }
        }
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE h:mm a"
        return "Meeting · \(formatter.string(from: date))"
    }

    static func provisionalUtterances(from update: LiveTranscriptUpdate, meetingID: UUID) -> [Utterance] {
        var segments = update.committed
        if !update.volatile.isEmpty {
            segments.append(TranscriptSegment(startMs: update.volatileStartMs, endMs: update.volatileStartMs, text: update.volatile))
        }
        return segments.filter { !$0.text.isEmpty }.map { seg in
            Utterance(meetingID: meetingID, speakerLabel: "Speaker", startMs: seg.startMs, endMs: max(seg.endMs, seg.startMs), text: seg.text, words: seg.words)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
