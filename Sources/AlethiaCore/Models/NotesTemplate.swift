import Foundation

/// A structure for generated meeting notes. Built-in templates cover common meeting
/// types; users can add their own.
public struct NotesTemplate: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var description: String
    /// Section headings the notes should contain, in order.
    public var sections: [String]
    /// Extra guidance for the language model (tone, what to emphasize).
    public var instructions: String
    public var isBuiltIn: Bool

    public init(id: String, name: String, description: String, sections: [String], instructions: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.sections = sections
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
    }

    public static let general = NotesTemplate(
        id: "general",
        name: "General",
        description: "Balanced summary for any meeting.",
        sections: ["Summary", "Key Points", "Decisions", "Action Items", "Open Questions"],
        instructions: "Be concise. Preserve names, numbers, dates and commitments exactly as stated.",
        isBuiltIn: true
    )

    public static let oneOnOne = NotesTemplate(
        id: "one-on-one",
        name: "1:1",
        description: "Manager / report check-ins.",
        sections: ["Highlights", "Wins", "Challenges", "Feedback", "Action Items", "Follow-ups for Next Time"],
        instructions: "Write in a supportive, direct tone. Attribute commitments to the person who made them.",
        isBuiltIn: true
    )

    public static let standup = NotesTemplate(
        id: "standup",
        name: "Standup",
        description: "Daily sync: done, doing, blocked.",
        sections: ["Yesterday", "Today", "Blockers", "Action Items"],
        instructions: "Group updates by person. Keep each bullet to one line.",
        isBuiltIn: true
    )

    public static let interview = NotesTemplate(
        id: "interview",
        name: "Interview",
        description: "Candidate or user-research interview.",
        sections: ["Background", "Key Answers", "Strengths", "Concerns", "Notable Quotes", "Next Steps"],
        instructions: "Quote the interviewee where helpful. Separate observations from judgments.",
        isBuiltIn: true
    )

    public static let salesCall = NotesTemplate(
        id: "sales",
        name: "Sales / Customer Call",
        description: "Discovery and customer conversations.",
        sections: ["Attendees", "Customer Context", "Pain Points", "Requirements", "Objections", "Next Steps"],
        instructions: "Capture budget, timeline, decision makers and competitors if mentioned.",
        isBuiltIn: true
    )

    public static let lecture = NotesTemplate(
        id: "lecture",
        name: "Lecture / Talk",
        description: "Classes, talks, and presentations.",
        sections: ["Overview", "Main Concepts", "Examples", "Questions Raised", "Further Reading"],
        instructions: "Organize by topic rather than chronologically. Define key terms.",
        isBuiltIn: true
    )

    public static let brainstorm = NotesTemplate(
        id: "brainstorm",
        name: "Brainstorm",
        description: "Idea generation sessions.",
        sections: ["Goal", "Ideas", "Favorites", "Parking Lot", "Next Steps"],
        instructions: "List every distinct idea. Do not merge ideas that differ in approach.",
        isBuiltIn: true
    )

    public static let builtIn: [NotesTemplate] = [
        .general, .oneOnOne, .standup, .interview, .salesCall, .lecture, .brainstorm,
    ]
}
