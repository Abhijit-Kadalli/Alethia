#if os(macOS)
import EventKit
import Foundation
import AlethiaCore

/// A calendar event that is happening now or about to start.
public struct CalendarContext: Sendable, Equatable {
    public var eventID: String
    public var title: String
    public var attendees: [String]
    public var startDate: Date
    public var endDate: Date
    public var isVideoCall: Bool

    public init(eventID: String, title: String, attendees: [String], startDate: Date, endDate: Date, isVideoCall: Bool) {
        self.eventID = eventID
        self.title = title
        self.attendees = attendees
        self.startDate = startDate
        self.endDate = endDate
        self.isVideoCall = isVideoCall
    }
}

/// Read-only EventKit access used to name meetings and pre-fill attendees.
@MainActor
public final class CalendarService {
    private let store = EKEventStore()
    private let log = Log("Calendar")

    public init() {}

    public var authorizationState: PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestAccess() async -> PermissionState {
        if authorizationState == .granted { return .granted }
        do {
            let granted = try await store.requestFullAccessToEvents()
            return granted ? .granted : .denied
        } catch {
            log.warning("calendar access failed: \(error.localizedDescription)")
            return .denied
        }
    }

    /// The event overlapping `date` (or starting within `lookahead`), preferring ones with attendees.
    public func currentEvent(at date: Date = Date(), lookahead: TimeInterval = 10 * 60, lookbehind: TimeInterval = 20 * 60) -> CalendarContext? {
        guard authorizationState == .granted else { return nil }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-lookbehind), end: date.addingTimeInterval(lookahead), calendars: nil)
        let events = store.events(matching: predicate).filter { event in
            !event.isAllDay && event.endDate > date.addingTimeInterval(-5 * 60)
        }
        let scored = events.map { event -> (EKEvent, Int) in
            var score = 0
            if event.startDate <= date, event.endDate >= date { score += 10 }
            if let attendees = event.attendees, attendees.count > 1 { score += 5 }
            if event.hasNotes || event.url != nil { score += 1 }
            score -= Int(abs(event.startDate.timeIntervalSince(date)) / 600)
            return (event, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return context(for: best)
    }

    private func context(for event: EKEvent) -> CalendarContext {
        let names = (event.attendees ?? []).compactMap { participant -> String? in
            if participant.isCurrentUser { return nil }
            let name = participant.name ?? ""
            if !name.isEmpty { return name }
            let url = participant.url.absoluteString
            return url.hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)) : nil
        }
        let text = [event.title ?? "", event.location ?? "", event.notes ?? "", event.url?.absoluteString ?? ""].joined(separator: " ").lowercased()
        let isVideo = ["zoom.us", "meet.google", "teams.microsoft", "webex", "whereby", "facetime", "around.co", "gather.town"].contains { text.contains($0) }
        return CalendarContext(
            eventID: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Meeting",
            attendees: Array(Set(names)).sorted(),
            startDate: event.startDate,
            endDate: event.endDate,
            isVideoCall: isVideo
        )
    }
}
#endif
