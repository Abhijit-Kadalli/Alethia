import Foundation
import AlethiaCore

/// Progress of a multi-file model download.
public struct DownloadProgress: Sendable, Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var currentFile: String
    public var filesDone: Int
    public var fileCount: Int

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    public init(receivedBytes: Int64 = 0, totalBytes: Int64 = 0, currentFile: String = "", filesDone: Int = 0, fileCount: Int = 0) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.currentFile = currentFile
        self.filesDone = filesDone
        self.fileCount = fileCount
    }
}

/// Downloads a Hugging Face repository snapshot into a local directory, preserving paths.
/// Files that already exist with the expected size are skipped, so interrupted downloads resume.
public actor HuggingFaceDownloader {
    public struct RemoteFile: Sendable, Equatable, Hashable {
        public var path: String
        public var size: Int64
    }

    public static let endpoint = URL(string: "https://huggingface.co")!

    private let session: URLSession
    private let log = Log("Download")

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 60 * 60
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Listing

    /// All files under `path` (recursively) in `repo` at `revision`.
    public func listFiles(repo: String, revision: String = "main", path: String = "") async throws -> [RemoteFile] {
        var components = URLComponents(url: Self.endpoint.appendingPathComponent("api/models/\(repo)/tree/\(revision)/\(path)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AlethiaError.modelDownloadFailed("Hugging Face returned HTTP \(code) for \(repo)")
        }
        struct Entry: Decodable {
            let type: String
            let path: String
            let size: Int64?
            let lfs: LFS?
            struct LFS: Decodable { let size: Int64? }
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries
            .filter { $0.type == "file" }
            .map { RemoteFile(path: $0.path, size: $0.lfs?.size ?? $0.size ?? 0) }
            .sorted { $0.path < $1.path }
    }

    // MARK: Download

    /// Download `files` from `repo` into `directory`, preserving relative paths.
    public func download(
        repo: String,
        revision: String = "main",
        files: [RemoteFile],
        to directory: URL,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var state = DownloadProgress(totalBytes: total, fileCount: files.count)

        for file in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            state.currentFile = file.path
            if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64,
               existing == file.size, file.size > 0 {
                state.receivedBytes += file.size
                state.filesDone += 1
                progress?(state)
                continue
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = Self.endpoint.appendingPathComponent("\(repo)/resolve/\(revision)/\(file.path)")
            let baseReceived = state.receivedBytes
            let baseState = state
            var attempt = 0
            while true {
                attempt += 1
                do {
                    try await downloadFile(from: url, to: destination) { written in
                        var snapshot = baseState
                        snapshot.receivedBytes = baseReceived + written
                        progress?(snapshot)
                    }
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log.warning("download failed (\(attempt)/3) \(file.path): \(error.localizedDescription)")
                    if attempt >= 3 {
                        throw AlethiaError.modelDownloadFailed("\(file.path): \(error.localizedDescription)")
                    }
                    try await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
            }
            state.receivedBytes = baseReceived + file.size
            state.filesDone += 1
            progress?(state)
        }
    }

    private func downloadFile(from url: URL, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = DownloadDelegate(onBytes: onBytes)
        let task = session.downloadTask(with: url)
        task.delegate = delegate
        let temporary: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

/// Bridges `URLSessionDownloadTask` callbacks to async/await. The finished file is moved out
/// of the system temporary location synchronously inside the callback, as URLSession requires.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<URL, Error>?
    private let onBytes: @Sendable (Int64) -> Void
    private var lastReport = Date.distantPast

    init(onBytes: @escaping @Sendable (Int64) -> Void) {
        self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.1 {
            lastReport = now
            onBytes(totalBytesWritten)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: AlethiaError.modelDownloadFailed("HTTP \(http.statusCode)"))
            continuation = nil
            return
        }
        let holding = FileManager.default.temporaryDirectory.appendingPathComponent("alethia-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: location, to: holding)
            continuation?.resume(returning: holding)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }
    }
}
