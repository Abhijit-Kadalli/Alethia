import Foundation

/// Where Alethia keeps its data. Everything lives under one directory so it is easy to
/// back up or delete:
///
/// ```
/// ~/Library/Application Support/Alethia/
///   alethia.sqlite          knowledge base
///   Recordings/<id>.wav     meeting audio (16 kHz mono)
///   Models/                 downloaded speech models
///   Logs/
/// ```
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let `default`: AppPaths = {
        if let override = ProcessInfo.processInfo.environment["ALETHIA_DATA_DIR"], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(root: base.appendingPathComponent("Alethia", isDirectory: true))
    }()

    public var database: URL { root.appendingPathComponent("alethia.sqlite") }
    /// 0.1.x knowledge file (`sessions` / `ConversationSession`). Imported once into `database`.
    public var legacyDatabase: URL { root.appendingPathComponent("knowledge.sqlite") }
    public var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }

    public func recordingURL(for meetingID: UUID) -> URL {
        recordings.appendingPathComponent("\(meetingID.uuidString).wav")
    }

    public func relativeRecordingPath(for meetingID: UUID) -> String {
        "Recordings/\(meetingID.uuidString).wav"
    }

    public func resolve(relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func ensureDirectories() throws {
        for dir in [root, recordings, models, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Total bytes used by recordings.
    public func recordingsSizeBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return items.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }
}
