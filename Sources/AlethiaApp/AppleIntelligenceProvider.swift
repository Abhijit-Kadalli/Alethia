import Foundation
import AlethiaCore
import AlethiaText
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence via the Foundation Models framework (macOS 26+).
/// Compiles to an unavailable stub on older SDKs.
struct AppleIntelligenceProvider: LanguageModelProvider {
    var id: String { "apple-intelligence" }
    var displayName: String { "Apple Intelligence" }

    static func make() -> (any LanguageModelProvider)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return AppleIntelligenceProvider()
        }
        #endif
        return nil
    }

    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    func complete(_ request: LanguageModelRequest) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: request.system)
            let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.maxTokens)
            let response = try await session.respond(to: request.user, options: options)
            return response.content
        }
        #endif
        throw AlethiaError.languageModel("Apple Intelligence requires macOS 26 or later.")
    }
}
