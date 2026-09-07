import Foundation

/// Loudness of the microphone versus system audio over a time range. Mirrors
/// `AlethiaAudio.SourceActivityFrame` so alignment can run without the audio module.
public struct SourceLoudness: Sendable, Equatable {
    public var startMs: Int
    public var endMs: Int
    public var microphoneRMS: Float
    public var systemRMS: Float

    public init(startMs: Int, endMs: Int, microphoneRMS: Float, systemRMS: Float) {
        self.startMs = startMs
        self.endMs = endMs
        self.microphoneRMS = microphoneRMS
        self.systemRMS = systemRMS
    }
}

/// Merges recognizer output with diarizer output into speaker-attributed utterances.
public struct TranscriptAligner: Sendable {
    /// Silence longer than this splits an utterance even when the speaker is unchanged.
    public var pauseSplitMs: Int
    /// Utterances longer than this are split at the next sentence end.
    public var maxUtteranceMs: Int
    /// Share of a cluster's words that must come from the microphone for it to be "You".
    public var selfThreshold: Float
    /// Ratio by which the microphone must exceed system audio to count as local.
    public var localMargin: Float

    public init(pauseSplitMs: Int = 1500, maxUtteranceMs: Int = 30_000, selfThreshold: Float = 0.7, localMargin: Float = 1.6) {
        self.pauseSplitMs = pauseSplitMs
        self.maxUtteranceMs = maxUtteranceMs
        self.selfThreshold = selfThreshold
        self.localMargin = localMargin
    }

    public struct Output: Sendable, Equatable {
        public var utterances: [Utterance]
        /// Diarizer cluster → display label used in `utterances`.
        public var clusterLabels: [String: String]
        /// Cluster identified as the local user, if any.
        public var selfCluster: String?
    }

    public func align(
        meetingID: UUID,
        segments: [TranscriptSegment],
        speakers: [SpeakerSegment],
        loudness: [SourceLoudness] = [],
        hasSystemAudio: Bool = false
    ) -> Output {
        let words = Self.flattenWords(segments)
        guard !words.isEmpty else {
            return Output(utterances: [], clusterLabels: [:], selfCluster: nil)
        }
        let sortedSpeakers = speakers.sorted { $0.startMs < $1.startMs }

        // 1. Attribute each word to the speaker segment it overlaps most (nearest when none).
        var attributed: [(word: TimedWord, cluster: String?)] = []
        attributed.reserveCapacity(words.count)
        for word in words {
            attributed.append((word, Self.bestCluster(for: word, in: sortedSpeakers)))
        }
        // Words with no overlap inherit their neighbour's cluster.
        for i in attributed.indices where attributed[i].cluster == nil {
            if i > 0, let prev = attributed[i - 1].cluster {
                attributed[i].cluster = prev
            } else if let next = attributed[(i + 1)...].first(where: { $0.cluster != nil })?.cluster {
                attributed[i].cluster = next
            }
        }

        // 2. Group consecutive words into utterances.
        var groups: [[(word: TimedWord, cluster: String?)]] = []
        var current: [(word: TimedWord, cluster: String?)] = []
        for item in attributed {
            if let last = current.last {
                let speakerChanged = last.cluster != item.cluster
                let longPause = item.word.startMs - last.word.endMs > pauseSplitMs
                let tooLong = (item.word.endMs - current[0].word.startMs) > maxUtteranceMs && Self.endsSentence(last.word.text)
                if speakerChanged || longPause || tooLong {
                    groups.append(current)
                    current = []
                }
            }
            current.append(item)
        }
        if !current.isEmpty { groups.append(current) }

        // 3. Decide which cluster is the local user, using per-word microphone dominance.
        var localVotes: [String: (local: Int, total: Int)] = [:]
        if hasSystemAudio, !loudness.isEmpty {
            for item in attributed {
                guard let cluster = item.cluster else { continue }
                var entry = localVotes[cluster] ?? (0, 0)
                if let dominant = Self.microphoneDominates(loudness, startMs: item.word.startMs, endMs: item.word.endMs, margin: localMargin) {
                    entry.total += 1
                    if dominant { entry.local += 1 }
                }
                localVotes[cluster] = entry
            }
        }
        var selfCluster: String?
        var bestRatio: Float = 0
        for (cluster, votes) in localVotes where votes.total >= 3 {
            let ratio = Float(votes.local) / Float(votes.total)
            if ratio >= selfThreshold, ratio > bestRatio {
                bestRatio = ratio
                selfCluster = cluster
            }
        }

        // 4. Labels in order of first appearance.
        var labels: [String: String] = [:]
        var nextIndex = 1
        for item in attributed {
            guard let cluster = item.cluster, labels[cluster] == nil else { continue }
            if cluster == selfCluster {
                labels[cluster] = Speaker.selfLabel
            } else {
                labels[cluster] = Speaker.provisionalName(index: nextIndex)
                nextIndex += 1
            }
        }

        // 5. Build utterances.
        var utterances: [Utterance] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let cluster = first.cluster
            let label = cluster.flatMap { labels[$0] } ?? Speaker.provisionalName(index: 1)
            let text = Self.joinWords(group.map(\.word.text))
            let isLocal: Bool? = hasSystemAudio && !loudness.isEmpty
                ? Self.microphoneDominates(loudness, startMs: first.word.startMs, endMs: last.word.endMs, margin: localMargin)
                : nil
            utterances.append(
                Utterance(
                    meetingID: meetingID,
                    speakerLabel: label,
                    startMs: first.word.startMs,
                    endMs: last.word.endMs,
                    text: text,
                    words: group.map(\.word),
                    isLocalSpeaker: isLocal
                )
            )
        }
        return Output(utterances: utterances, clusterLabels: labels, selfCluster: selfCluster)
    }

    // MARK: - Helpers

    /// Uses word timings when present; otherwise fabricates evenly spaced words from each segment.
    static func flattenWords(_ segments: [TranscriptSegment]) -> [TimedWord] {
        var out: [TimedWord] = []
        for segment in segments.sorted(by: { $0.startMs < $1.startMs }) {
            if !segment.words.isEmpty {
                out.append(contentsOf: segment.words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
                continue
            }
            let tokens = segment.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !tokens.isEmpty else { continue }
            let span = max(segment.endMs - segment.startMs, tokens.count)
            for (i, token) in tokens.enumerated() {
                let start = segment.startMs + span * i / tokens.count
                let end = segment.startMs + span * (i + 1) / tokens.count
                out.append(TimedWord(text: token, startMs: start, endMs: end))
            }
        }
        return out
    }

    static func bestCluster(for word: TimedWord, in speakers: [SpeakerSegment]) -> String? {
        var best: (cluster: String, overlap: Int)?
        let mid = (word.startMs + word.endMs) / 2
        var nearest: (cluster: String, distance: Int)?
        for segment in speakers {
            let overlap = min(word.endMs, segment.endMs) - max(word.startMs, segment.startMs)
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (segment.clusterID, overlap)
            }
            let distance = mid < segment.startMs ? segment.startMs - mid : (mid > segment.endMs ? mid - segment.endMs : 0)
            if nearest == nil || distance < nearest!.distance {
                nearest = (segment.clusterID, distance)
            }
        }
        if let best { return best.cluster }
        // Snap to a nearby segment if the gap is small (diarizer boundaries are ~100 ms coarse).
        if let nearest, nearest.distance <= 400 { return nearest.cluster }
        return nil
    }

    static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return ".?!".contains(last)
    }

    /// Joins recognizer tokens, avoiding spaces before punctuation.
    static func joinWords(_ tokens: [String]) -> String {
        var out = ""
        for token in tokens {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if out.isEmpty {
                out = t
            } else if let first = t.first, ",.?!;:%)".contains(first) {
                out += t
            } else if let last = out.last, "($".contains(last) {
                out += t
            } else {
                out += " " + t
            }
        }
        return out
    }

    static func microphoneDominates(_ frames: [SourceLoudness], startMs: Int, endMs: Int, margin: Float) -> Bool? {
        var mic: Float = 0
        var sys: Float = 0
        var count = 0
        for frame in frames where frame.endMs > startMs && frame.startMs < endMs {
            mic += frame.microphoneRMS
            sys += frame.systemRMS
            count += 1
        }
        guard count > 0 else { return nil }
        let floor: Float = 0.004
        if mic < floor && sys < floor { return nil }
        if mic > sys * margin { return true }
        if sys > mic * margin { return false }
        return nil
    }
}

/// Matches diarizer clusters against the persistent speaker gallery.
public struct SpeakerMatcher: Sendable {
    /// Minimum cosine similarity to suggest a name.
    public var suggestThreshold: Float
    /// Similarity above which the name is applied automatically.
    public var autoAcceptThreshold: Float

    public init(suggestThreshold: Float = 0.55, autoAcceptThreshold: Float = 0.75) {
        self.suggestThreshold = suggestThreshold
        self.autoAcceptThreshold = autoAcceptThreshold
    }

    public struct Match: Sendable, Equatable {
        public var clusterID: String
        public var speaker: Speaker
        public var similarity: Float
        public var autoAccepted: Bool
    }

    /// Each gallery speaker is used at most once (best cluster wins).
    public func match(clusters: [String: [Float]], gallery: [Speaker]) -> [Match] {
        let candidates = gallery.filter { $0.isNamed && !$0.embedding.isEmpty }
        var pairs: [(cluster: String, speaker: Speaker, score: Float)] = []
        for (cluster, embedding) in clusters where !embedding.isEmpty {
            for speaker in candidates where speaker.embedding.count == embedding.count {
                let score = EmbeddingMath.cosineSimilarity(embedding, speaker.embedding)
                if score >= suggestThreshold {
                    pairs.append((cluster, speaker, score))
                }
            }
        }
        pairs.sort { $0.score > $1.score }
        var usedClusters = Set<String>()
        var usedSpeakers = Set<UUID>()
        var matches: [Match] = []
        for pair in pairs where !usedClusters.contains(pair.cluster) && !usedSpeakers.contains(pair.speaker.id) {
            usedClusters.insert(pair.cluster)
            usedSpeakers.insert(pair.speaker.id)
            matches.append(Match(clusterID: pair.cluster, speaker: pair.speaker, similarity: pair.score, autoAccepted: pair.score >= autoAcceptThreshold))
        }
        return matches.sorted { $0.clusterID < $1.clusterID }
    }

    /// Applies matches to utterances: auto-accepted names replace labels; others become suggestions.
    public func apply(_ matches: [Match], to utterances: inout [Utterance], clusterLabels: [String: String]) {
        guard !matches.isEmpty else { return }
        var labelToMatch: [String: Match] = [:]
        for match in matches {
            if let label = clusterLabels[match.clusterID] { labelToMatch[label] = match }
        }
        for i in utterances.indices {
            guard let match = labelToMatch[utterances[i].speakerLabel] else { continue }
            if match.autoAccepted {
                utterances[i].speakerLabel = match.speaker.displayName
                utterances[i].speakerID = match.speaker.id
                utterances[i].matchConfidence = match.similarity
                utterances[i].suggestedSpeakerName = nil
            } else {
                utterances[i].suggestedSpeakerName = match.speaker.displayName
                utterances[i].matchConfidence = match.similarity
            }
        }
    }
}
