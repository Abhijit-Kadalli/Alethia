import Foundation
import SwiftUI

/// Sidebar sections of the Hub window.
enum HubSection: String, CaseIterable, Identifiable, Hashable {
    case meetings
    case dictations
    case vocabulary
    case speakers
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings: return "Meetings"
        case .dictations: return "Dictation history"
        case .vocabulary: return "Dictionary & snippets"
        case .speakers: return "Speakers"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .meetings: return "person.2.wave.2"
        case .dictations: return "text.cursor"
        case .vocabulary: return "character.book.closed"
        case .speakers: return "person.crop.circle.badge.checkmark"
        case .settings: return "gearshape"
        }
    }
}

/// Settings panes inside the settings section.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case dictation
    case meetings
    case models
    case intelligence
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .meetings: return "Meetings"
        case .models: return "Models"
        case .intelligence: return "AI"
        case .privacy: return "Privacy & data"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .dictation: return "mic"
        case .meetings: return "record.circle"
        case .models: return "cpu"
        case .intelligence: return "sparkles"
        case .privacy: return "lock.shield"
        }
    }
}

/// Process-wide navigation state so the menu bar and notifications can deep-link into the Hub.
@MainActor
final class HubNavigation: ObservableObject {
    static let shared = HubNavigation()

    @Published var section: HubSection = .meetings
    @Published var selectedMeetingID: UUID?
    @Published var settingsPane: SettingsPane = .general
    @Published var searchQuery = ""

    func select(meetingID: UUID) {
        section = .meetings
        selectedMeetingID = meetingID
    }

    func select(section: HubSection, pane: SettingsPane? = nil) {
        self.section = section
        if let pane { settingsPane = pane }
    }
}
