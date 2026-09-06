import Foundation
#if canImport(os)
import os
#endif

/// Thin logging facade. Uses the unified logging system on Apple platforms and
/// stderr elsewhere (Linux test runs).
public struct Log: Sendable {
    public let category: String

    public init(_ category: String) {
        self.category = category
    }

    #if canImport(os)
    private var logger: Logger { Logger(subsystem: "app.alethia", category: category) }
    #endif

    public func debug(_ message: @autoclosure () -> String) {
        #if canImport(os)
        logger.debug("\(message(), privacy: .public)")
        #else
        emit("DEBUG", message())
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        #if canImport(os)
        logger.info("\(message(), privacy: .public)")
        #else
        emit("INFO", message())
        #endif
    }

    public func warning(_ message: @autoclosure () -> String) {
        #if canImport(os)
        logger.warning("\(message(), privacy: .public)")
        #else
        emit("WARN", message())
        #endif
    }

    public func error(_ message: @autoclosure () -> String) {
        #if canImport(os)
        logger.error("\(message(), privacy: .public)")
        #else
        emit("ERROR", message())
        #endif
    }

    private func emit(_ level: String, _ message: String) {
        FileHandle.standardError.write("[\(level)] [\(category)] \(message)\n".data(using: .utf8) ?? Data())
    }
}
