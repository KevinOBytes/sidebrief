import Foundation
import EventKit
import Combine

/// Calendar event representing a scheduled meeting.
public struct CalendarMeetingEvent: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let attendees: [String]
    public let locationOrURL: String?
    public let notes: String?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        attendees: [String] = [],
        locationOrURL: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendees = attendees
        self.locationOrURL = locationOrURL
        self.notes = notes
    }

    public var isHappeningNow: Bool {
        let now = Date()
        return startDate <= now && now <= endDate
    }

    public var minutesUntilStart: Int {
        let diff = startDate.timeIntervalSince(Date())
        return max(0, Int(round(diff / 60.0)))
    }

    public var formattedTimeRange: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }

    public var statusBadge: String {
        if isHappeningNow {
            return "Happening Now"
        } else if minutesUntilStart <= 0 {
            return "Starting Now"
        } else if minutesUntilStart < 60 {
            return "in \(minutesUntilStart)m"
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: startDate)
        }
    }
}

/// Service managing macOS Calendar (EventKit) integration, detecting scheduled calls,
/// extracting meeting links (Zoom/Meet/Teams), and providing zero-friction meeting pre-population.
public final class CalendarService: ObservableObject, @unchecked Sendable {
    public static let shared = CalendarService()

    private let eventStore = EKEventStore()
    private let queue = DispatchQueue(label: "com.sidebrief.calendar", qos: .userInitiated)

    @Published public private(set) var upcomingEvents: [CalendarMeetingEvent] = []
    @Published public private(set) var nextMeeting: CalendarMeetingEvent? = nil
    @Published public private(set) var hasCalendarAccess: Bool = false

    private var refreshTimer: Timer?

    private init() {
        checkAuthorization()
        startPeriodicRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Authorization

    public func checkAuthorization() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            DispatchQueue.main.async {
                self.hasCalendarAccess = (status == .fullAccess)
            }
        } else {
            DispatchQueue.main.async {
                self.hasCalendarAccess = (status == .authorized)
            }
        }
        if hasCalendarAccess {
            fetchUpcomingMeetings()
        }
    }

    public func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.hasCalendarAccess = granted
                    if granted {
                        self?.fetchUpcomingMeetings()
                    }
                    completion(granted)
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.hasCalendarAccess = granted
                    if granted {
                        self?.fetchUpcomingMeetings()
                    }
                    completion(granted)
                }
            }
        }
    }

    // MARK: - Event Fetching

    public func fetchUpcomingMeetings() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let calendars = self.eventStore.calendars(for: .event)
            let start = Calendar.current.date(byAdding: .minute, value: -15, to: Date()) ?? Date()
            let end = Calendar.current.date(byAdding: .hour, value: 12, to: Date()) ?? Date()

            let predicate = self.eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
            let rawEvents = self.eventStore.events(matching: predicate)

            let filtered = rawEvents.compactMap { ekEvent -> CalendarMeetingEvent? in
                // Skip cancelled or declined invitations
                if let attendees = ekEvent.attendees {
                    let userDeclined = attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
                    if userDeclined { return nil }
                }

                let attendeeNames = ekEvent.attendees?.compactMap { $0.name ?? $0.url.absoluteString } ?? []

                // Look for meeting URL in location or notes (Zoom, Google Meet, Teams, Webex)
                var detectedLink: String? = nil
                if let loc = ekEvent.location, loc.contains("http") || loc.contains("zoom.us") || loc.contains("meet.google") || loc.contains("teams.microsoft") {
                    detectedLink = loc
                } else if let notes = ekEvent.notes {
                    if let range = notes.range(of: #"https?://[^\s]+"#, options: .regularExpression) {
                        detectedLink = String(notes[range])
                    }
                }

                return CalendarMeetingEvent(
                    id: ekEvent.eventIdentifier ?? UUID().uuidString,
                    title: ekEvent.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? ekEvent.title! : "Untitled Meeting",
                    startDate: ekEvent.startDate,
                    endDate: ekEvent.endDate,
                    attendees: attendeeNames,
                    locationOrURL: detectedLink ?? ekEvent.location,
                    notes: ekEvent.notes
                )
            }.sorted { $0.startDate < $1.startDate }

            DispatchQueue.main.async {
                self.upcomingEvents = filtered
                self.nextMeeting = filtered.first { $0.endDate > Date() }
            }
        }
    }

    private func startPeriodicRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                self?.fetchUpcomingMeetings()
            }
        }
    }
}
