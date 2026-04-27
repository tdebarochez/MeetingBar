import Foundation
import EventKit
import Combine

/// Represents a meeting we care about: accepted, in the future today, with a video link.
struct Meeting: Identifiable, Equatable {
    let id: String          // EKEvent.eventIdentifier
    let title: String
    let startDate: Date
    let endDate: Date
    let videoURL: URL
    let provider: VideoProvider
    let attendees: [Attendee]
    let notes: String?
    let userEmail: String?

    enum VideoProvider: String {
        case meet = "Google Meet"
        case zoom = "Zoom"
        case teams = "Microsoft Teams"
        case other = "Video call"
    }

    struct Attendee: Equatable {
        let name: String
        let email: String?
        let status: EKParticipantStatus
        let isCurrentUser: Bool
    }

    var joinURL: URL {
        guard provider == .meet,
              let email = userEmail,
              var components = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)
        else { return videoURL }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "authuser", value: email))
        components.queryItems = items
        return components.url ?? videoURL
    }
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var nextMeeting: Meeting?
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private let eventStore = EKEventStore()
    private var refreshTimer: Timer?
    private var storeChangedObserver: NSObjectProtocol?

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        // EventKit posts this when calendars/events change. We refresh on it
        // so the app reacts immediately if you accept a new invite.
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let observer = storeChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        refreshTimer?.invalidate()
    }

    // MARK: - Authorization

    func requestAccess() async {
        do {
            // macOS 14+ API. The Info.plist must contain
            // NSCalendarsFullAccessUsageDescription or this silently fails.
            let granted = try await eventStore.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                refresh()
                startPeriodicRefresh()
            } else {
                lastError = "Calendar access denied. Grant access in System Settings → Privacy & Security → Calendars."
            }
        } catch {
            lastError = "Failed to request calendar access: \(error.localizedDescription)"
        }
    }

    // MARK: - Refresh loop

    /// We refresh every 30s as a safety net. The EKEventStoreChanged
    /// notification handles most updates, but a timer catches cases where
    /// the "next meeting" just naturally changes because time passed.
    func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard authorizationStatus == .fullAccess else { return }

        let now = Date()
        // Look from now through end of today. EventKit recommends the
        // shortest range you can get away with for performance.
        let calendar = Calendar.current
        guard let endOfDay = calendar.date(
            bySettingHour: 23, minute: 59, second: 59, of: now
        ) else { return }

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endOfDay,
            calendars: nil // all calendars the user has access to
        )

        let events = eventStore.events(matching: predicate)

        // Filter: accepted only, has a video link, hasn't ended yet.
        let candidates: [Meeting] = events.compactMap { event in
            guard event.endDate > now else { return nil }
            guard isPersonallyAccepted(event) else { return nil }
            guard let (url, provider) = extractVideoURL(from: event) else { return nil }
            guard let id = event.eventIdentifier else { return nil }
            let attendees = (event.attendees ?? []).map { participant in
                let email = participant.url.scheme == "mailto"
                    ? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    : nil
                return Meeting.Attendee(
                    name: participant.name ?? email ?? "Unknown",
                    email: email,
                    status: participant.participantStatus,
                    isCurrentUser: participant.isCurrentUser
                )
            }
            let userEmail = attendees.first(where: { $0.isCurrentUser })?.email
                ?? Self.email(from: event.organizer)
                ?? event.calendar.source?.title
            return Meeting(
                id: id,
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                videoURL: url,
                provider: provider,
                attendees: attendees,
                notes: Self.cleanNotes(event.notes),
                userEmail: userEmail
            )
        }

        // Earliest upcoming wins. If something is already in progress and
        // has a video link, we still show it — you might want to join late.
        nextMeeting = candidates.min(by: { $0.startDate < $1.startDate })
    }

    // MARK: - Helpers

    private static func email(from participant: EKParticipant?) -> String? {
        guard let participant, participant.url.scheme == "mailto" else { return nil }
        return participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }

    private static func cleanNotes(_ notes: String?) -> String? {
        guard let notes else { return nil }
        if let range = notes.range(of: "-::~:~::~:~:~:~:~:~:~:~:~:~:~:~") {
            let trimmed = notes[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return notes
    }

    private func isPersonallyAccepted(_ event: EKEvent) -> Bool {
        if event.organizer?.isCurrentUser == true {
            return true
        }
        guard let attendees = event.attendees, !attendees.isEmpty else {
            return !event.calendar.isSubscribed
        }
        if let me = attendees.first(where: { $0.isCurrentUser }) {
            return me.participantStatus == .accepted
        }
        return false
    }

    /// Video links show up in one of three places depending on who created
    /// the invite: the structured `url` field (Google Calendar), the
    /// `location` field (Outlook sometimes), or the `notes` body (Zoom,
    /// Teams, manually-pasted links). We check all three.
    private func extractVideoURL(from event: EKEvent) -> (URL, Meeting.VideoProvider)? {
        let candidates: [String] = [
            event.url?.absoluteString,
            event.location,
            event.notes
        ].compactMap { $0 }

        for text in candidates {
            if let match = findVideoURL(in: text) {
                return match
            }
        }
        return nil
    }

    private func findVideoURL(in text: String) -> (URL, Meeting.VideoProvider)? {
        // Order matters: check Meet first because a Zoom link pasted into
        // notes could coexist with a Meet link from the organizer's workflow.
        let patterns: [(String, Meeting.VideoProvider)] = [
            (#"https://meet\.google\.com/[a-z0-9\-]+"#, .meet),
            (#"https://[a-z0-9\-]*\.?zoom\.us/j/[0-9]+(\?[^\s]*)?"#, .zoom),
            (#"https://[a-z0-9\-]*\.?zoom\.us/my/[a-z0-9\-_.]+"#, .zoom),
            (#"https://teams\.microsoft\.com/l/meetup-join/[^\s<>\"]+"#, .teams),
            (#"https://teams\.live\.com/meet/[^\s<>\"]+"#, .teams)
        ]

        for (pattern, provider) in patterns {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               let url = URL(string: String(text[range])) {
                return (url, provider)
            }
        }
        return nil
    }
}
