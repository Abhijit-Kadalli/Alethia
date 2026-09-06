#if os(macOS)
import Combine
import Foundation
import AlethiaAudio
import AlethiaCore
import AlethiaKnowledge
import AlethiaSpeech

/// Produces notes for a processed meeting. Implemented by `AlethiaText.NotesGenerator`
/// (heuristic or LLM); kept as a protocol so this module has no text dependency.
public protocol MeetingNotesProducing: Sendable {
    func produceNotes(for meeting: Meeting, template: NotesTemplate) async -> ProducedNotes
}

public struct ProducedNotes: Sendable, Equatable {
    public var markdown: String
    public var summary: String
    public var suggestedTitle: String?
    public var producedBy: String

    public init(markdown: String, summary: String, suggestedTitle: String? = nil, producedBy: String) {
        self.markdown = markdown
        self.summary = summary
        self.suggestedTitle = suggestedTitle
        self.producedBy = producedBy
    }
}

/// Turns a finished recording into a transcript with speakers and notes. Runs one meeting at a
/// time in the background; progress is published for the UI.
@MainActor
public final class MeetingProcessor: ObservableObject {
    public struct Progress: Equatable, Sendable {
        public var meetingID: UUID
        public var stage: String
        public var fraction: Double
    }

    @Published public private(set) var progress: [UUID: Progress] = [:]

    private let store: KnowledgeStore
    private let speech: any SpeechEngineProtocol
    private let settings: SettingsStore
    private let paths: AppPaths
    private var notes: (any MeetingNotesProducing)?
    private var queue: [(UUID, MeetingCaptureResult?)] = []
    private var worker: Task<Void, Never>?
    private let log = Log("Processing")

    public init(store: KnowledgeStore, speech: any SpeechEngineProtocol, settings: SettingsStore, paths: AppPaths,
                notes: (any MeetingNotesProducing)? = nil) {
        self.store = store
        self.speech = speech
        self.settings = settings
        self.paths = paths
        self.notes = notes
    }

    public func setNotesProducer(_ producer: (any MeetingNotesProducing)?) {
        notes = producer
    }

    public var isBusy: Bool { !progress.isEmpty }

    /// Queue a freshly recorded meeting.
    public func enqueue(meetingID: UUID, capture: MeetingCaptureResult) {
        queue.append((meetingID, capture))
        progress[meetingID] = Progress(meetingID: meetingID, stage: "Queued", fraction: 0)
        pump()
    }

    /// Re-run recognition for a saved meeting whose audio is still on disk.
    public func reprocess(meetingID: UUID) {
        guard progress[meetingID] == nil else { return }
        queue.append((meetingID, nil))
        progress[meetingID] = Progress(meetingID: meetingID, stage: "Queued", fraction: 0)
        pump()
    }

    /// Meetings interrupted by a crash/quit while recording or processing.
    public func recoverInterrupted() {
        guard let meetings = try? store.meetingsInProgress() else { return }
        for meeting in meetings {
            if let path = meeting.audioPath, FileManager.default.fileExists(atPath: paths.resolve(relativePath: path).path) {
                try? WAVFileWriter.repairHeader(at: paths.resolve(relativePath: path), sampleRate: 16_000)
                reprocess(meetingID: meeting.id)
            } else {
                try? store.updateStatus(meetingID: meeting.id, status: .failed, error: "Recording was interrupted and no audio was saved.")
            }
        }
    }

    /// Regenerate notes only (e.g. after changing template or connecting an LLM).
    public func regenerateNotes(meetingID: UUID, templateID: String?) async {
        guard var meeting = try? store.meeting(id: meetingID) else { return }
        let template = resolveTemplate(templateID ?? meeting.enhancedNotesTemplateID)
        progress[meetingID] = Progress(meetingID: meetingID, stage: "Writing notes", fraction: 0.9)
        defer { progress[meetingID] = nil }
        guard let notes else { return }
        let produced = await notes.produceNotes(for: meeting, template: template)
        meeting.enhancedNotes = produced.markdown
        try? store.updateEnhancedNotes(meetingID: meetingID, markdown: produced.markdown, templateID: template.id,
                                       producedBy: produced.producedBy, summary: produced.summary)
    }

    // MARK: Pipeline

    private func pump() {
        guard worker == nil, !queue.isEmpty else { return }
        let (meetingID, capture) = queue.removeFirst()
        worker = Task { [weak self] in
            await self?.process(meetingID: meetingID, capture: capture)
            await MainActor.run {
                self?.worker = nil
                self?.pump()
            }
        }
    }

    private func setProgress(_ meetingID: UUID, _ stage: String, _ fraction: Double) {
        progress[meetingID] = Progress(meetingID: meetingID, stage: stage, fraction: fraction)
    }

    private func process(meetingID: UUID, capture: MeetingCaptureResult?) async {
        guard var meeting = try? store.meeting(id: meetingID) else {
            progress[meetingID] = nil
            return
        }
        let audioURL = capture?.audioURL ?? meeting.audioPath.map { paths.resolve(relativePath: $0) }
        guard let audioURL, FileManager.default.fileExists(atPath: audioURL.path) else {
            try? store.updateStatus(meetingID: meetingID, status: .failed, error: "The recording file is missing.")
            progress[meetingID] = nil
            return
        }
        try? store.updateStatus(meetingID: meetingID, status: .processing, error: nil)
        let started = Date()

        do {
            setProgress(meetingID, "Loading models", 0.02)
            try await speech.prepare()

            setProgress(meetingID, "Transcribing", 0.05)
            let progressSink: @Sendable (Double) -> Void = { [weak self] value in
                Task { @MainActor in self?.setProgress(meetingID, "Transcribing", 0.05 + value * 0.5) }
            }
            let segment = try await speech.transcribeFile(audioURL, progress: progressSink)

            setProgress(meetingID, "Identifying speakers", 0.58)
            let samples = try await Self.loadSamples(from: audioURL)
            var speakers: [SpeakerSegment] = []
            do {
                let diarizeSink: @Sendable (Double) -> Void = { [weak self] value in
                    Task { @MainActor in self?.setProgress(meetingID, "Identifying speakers", 0.58 + value * 0.3) }
                }
                speakers = try await speech.diarize(samples, progress: diarizeSink)
            } catch {
                log.warning("diarization skipped: \(error.localizedDescription)")
            }

            setProgress(meetingID, "Assembling transcript", 0.9)
            let loudness = (capture?.activity ?? []).map {
                SourceLoudness(startMs: $0.startMs, endMs: $0.endMs, microphoneRMS: $0.microphoneRMS, systemRMS: $0.systemRMS)
            }
            let hasSystem = capture?.includedSystemAudio ?? (meeting.source == .microphoneAndSystem)
            let aligned = TranscriptAligner().align(
                meetingID: meetingID, segments: [segment], speakers: speakers, loudness: loudness, hasSystemAudio: hasSystem
            )
            var utterances = aligned.utterances

            // Match clusters against known speakers and update the "You" voiceprint.
            let clusterEmbeddings = Self.clusterEmbeddings(speakers)
            let gallery = (try? store.speakers()) ?? []
            let matcher = SpeakerMatcher()
            let matches = matcher.match(clusters: clusterEmbeddings, gallery: gallery)
            matcher.apply(matches, to: &utterances, clusterLabels: aligned.clusterLabels)
            if let selfCluster = aligned.selfCluster, let embedding = clusterEmbeddings[selfCluster] {
                updateSelfSpeaker(embedding: embedding, utterances: &utterances)
            }

            meeting.utterances = utterances
            meeting.durationMs = capture?.durationMs ?? meeting.durationMs
            meeting.endedAt = meeting.endedAt ?? capture?.endedAt ?? Date()
            meeting.status = .ready
            meeting.processingError = nil
            try store.updateMeetingMetadata(meeting)
            try store.replaceUtterances(meetingID: meetingID, utterances)

            setProgress(meetingID, "Writing notes", 0.93)
            let template = resolveTemplate(meeting.enhancedNotesTemplateID ?? settings.load().meetings.defaultTemplateID)
            if let notes, !utterances.isEmpty {
                let produced = await notes.produceNotes(for: meeting, template: template)
                try store.updateEnhancedNotes(meetingID: meetingID, markdown: produced.markdown, templateID: template.id,
                                              producedBy: produced.producedBy, summary: produced.summary)
                if let title = produced.suggestedTitle, Self.isGenericTitle(meeting.title) {
                    try store.updateTitle(meetingID: meetingID, title: title)
                }
            }
            try store.updateStatus(meetingID: meetingID, status: .ready, error: nil)

            if !settings.load().meetings.keepAudio {
                try? FileManager.default.removeItem(at: audioURL)
                meeting.audioPath = nil
                try? store.updateMeetingMetadata(meeting)
            }
            log.info("processed \(meetingID) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(utterances.count) utterances")
        } catch {
            log.error("processing failed \(meetingID): \(error.localizedDescription)")
            try? store.updateStatus(meetingID: meetingID, status: .failed, error: error.localizedDescription)
        }
        progress[meetingID] = nil
    }

    // MARK: Helpers

    private func resolveTemplate(_ id: String?) -> NotesTemplate {
        let all = (try? store.allTemplates()) ?? NotesTemplate.builtIn
        return all.first { $0.id == id } ?? .general
    }

    private func updateSelfSpeaker(embedding: [Float], utterances: inout [Utterance]) {
        let existing = ((try? store.speakers()) ?? []).first { $0.isSelf }
        var me = existing ?? Speaker(displayName: "You", embedding: embedding, isSelf: true)
        if existing != nil {
            me.embedding = EmbeddingMath.updateMean(me.embedding, count: me.sampleCount, with: embedding)
            me.sampleCount += 1
        } else {
            me.sampleCount = 1
        }
        me.updatedAt = Date()
        try? store.upsertSpeaker(me)
        for i in utterances.indices where utterances[i].isLocalSpeaker == true {
            utterances[i].speakerID = me.id
            utterances[i].speakerLabel = me.displayName
        }
    }

    static func clusterEmbeddings(_ segments: [SpeakerSegment]) -> [String: [Float]] {
        var sums: [String: ([Float], Int)] = [:]
        for segment in segments {
            guard let embedding = segment.embedding, !embedding.isEmpty else { continue }
            var (sum, count) = sums[segment.clusterID] ?? ([Float](repeating: 0, count: embedding.count), 0)
            guard sum.count == embedding.count else { continue }
            for i in 0..<sum.count { sum[i] += embedding[i] }
            count += 1
            sums[segment.clusterID] = (sum, count)
        }
        return sums.mapValues { sum, count in
            let mean = sum.map { $0 / Float(count) }
            let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return norm > 0 ? mean.map { $0 / norm } : mean
        }
    }

    static func isGenericTitle(_ title: String) -> Bool {
        title.hasPrefix("Meeting ·") || title.hasSuffix(" call") || title.isEmpty
    }

    static func loadSamples(from url: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let decoded = try WAVCodec.decode(data)
            return decoded.samples
        }.value
    }
}
#endif
