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
        let text = message()
        #if canImport(os)
        logger.debug("\(text, privacy: .public)")
        #else
        emit("DEBUG", text)
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        logger.info("\(text, privacy: .public)")
        #else
        emit("INFO", text)
        #endif
    }

    public func warning(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        logger.warning("\(text, privacy: .public)")
        #else
        emit("WARN", text)
        #endif
    }

    public func error(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        logger.error("\(text, privacy: .public)")
        #else
        emit("ERROR", text)
        #endif
    }

    private func emit(_ level: String, _ message: String) {
        FileHandle.standardError.write("[\(level)] [\(category)] \(message)\n".data(using: .utf8) ?? Data())
    }
}
