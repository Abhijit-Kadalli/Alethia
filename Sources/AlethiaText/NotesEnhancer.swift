import Foundation
import AlethiaCore

/// Compatibility wrapper around `NotesGenerator`.
public struct NotesEnhancer: Sendable {
    public struct Result: Sendable, Hashable {
        public var notes: String
        public var summary: String
        public var producedBy: String

        public init(notes: String, summary: String, producedBy: String) {
            self.notes = notes
            self.summary = summary
            self.producedBy = producedBy
        }
    }

    private let generator: NotesGenerator

    public init(provider: LanguageModelProvider?) {
        self.generator = NotesGenerator(provider: provider)
    }

    public func enhance(meeting: Meeting, template: NotesTemplate) async -> Result {
        let notes = await generator.generate(meeting: meeting, template: template)
        return Result(notes: notes.markdown, summary: notes.summary, producedBy: notes.producedBy)
    }
}
