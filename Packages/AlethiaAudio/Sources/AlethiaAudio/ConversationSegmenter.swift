import Foundation
import AlethiaCore

public struct ConversationSegment: Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var speechMs: Int
    public var pcm: [Float]

    public init(startedAt: Date = Date(), endedAt: Date? = nil, speechMs: Int = 0, pcm: [Float] = []) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.speechMs = speechMs
        self.pcm = pcm
    }
}

public final class ConversationSegmenter: @unchecked Sendable {
    public enum Event: Sendable {
        case opened(ConversationSegment)
        case closed(ConversationSegment)
        case discarded
    }

    private let config: PipelineConfig
    private var active: ConversationSegment?
    private var silenceMs = 0
    private var windowSpeechMs = 0
    private var windowElapsedMs = 0

    public init(config: PipelineConfig = .default) {
        self.config = config
    }

    public func process(isSpeech: Bool, frame: [Float], frameMs: Int) -> Event? {
        windowElapsedMs += frameMs
        if isSpeech { windowSpeechMs += frameMs }

        if active == nil {
            let useful = windowSpeechMs >= config.minConversationSpeechMs
                || (windowSpeechMs >= 2000 && windowElapsedMs <= 8000)
            if useful && isSpeech {
                var seg = ConversationSegment()
                seg.pcm.append(contentsOf: frame)
                seg.speechMs = frameMs
                active = seg
                silenceMs = 0
                return .opened(seg)
            }
            if windowElapsedMs > 8000 {
                windowElapsedMs = 0
                windowSpeechMs = 0
            }
            return nil
        }

        // Active conversation
        active?.pcm.append(contentsOf: frame)
        if isSpeech {
            active?.speechMs += frameMs
            silenceMs = 0
        } else {
            silenceMs += frameMs
            // Conversation hangover is longer than VAD close so short pauses stay in-session.
            let closeMs = max(config.closeSilenceMs * 9, 4500)
            if silenceMs >= closeMs {
                return closeActive()
            }
        }
        return nil
    }

    public func forceClose() -> Event? {
        guard active != nil else { return nil }
        return closeActive()
    }

    private func closeActive() -> Event {
        guard var seg = active else { return .discarded }
        active = nil
        silenceMs = 0
        windowElapsedMs = 0
        windowSpeechMs = 0
        seg.endedAt = Date()
        if seg.speechMs < config.minConversationSpeechMs {
            return .discarded
        }
        return .closed(seg)
    }
}
