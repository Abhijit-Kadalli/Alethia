import Foundation

/// A person whose voice Alethia has seen. Embeddings are averaged across meetings so
/// the same person can be recognized again once the user has labeled them.
public struct Speaker: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    /// Mean speaker embedding (dimension depends on the diarizer, typically 256).
    public var embedding: [Float]
    /// Number of segments that contributed to `embedding`.
    public var sampleCount: Int
    /// True when this profile represents the current user.
    public var isSelf: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        embedding: [Float] = [],
        sampleCount: Int = 0,
        isSelf: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.isSelf = isSelf
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when the user gave this speaker a real name (not `Speaker 3`).
    public var isNamed: Bool { !Self.isProvisionalName(displayName) }

    public static func isProvisionalName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^(Person|Speaker)\s+\d+$"#, options: .regularExpression) != nil
    }

    public static func provisionalName(index: Int) -> String {
        "Speaker \(max(index, 1))"
    }

    public static let selfLabel = "You"
}

public enum EmbeddingMath {
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    /// Running mean update: `mean' = (mean * n + sample) / (n + 1)`.
    public static func updateMean(_ mean: [Float], count: Int, with sample: [Float]) -> [Float] {
        guard !mean.isEmpty, mean.count == sample.count, count > 0 else { return sample }
        let n = Float(count)
        return zip(mean, sample).map { ($0 * n + $1) / (n + 1) }
    }
}
