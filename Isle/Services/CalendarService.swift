import AppKit
import EventKit

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: NSColor

    static func == (a: CalEvent, b: CalEvent) -> Bool {
        a.id == b.id && a.title == b.title && a.start == b.start && a.end == b.end
    }
}

/// Today's remaining events from the system calendars (read-only).
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var events: [CalEvent] = []

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var asked = false
    private var injected = false

    var hasAccess: Bool { status == .fullAccess }

    /// Called when the calendar card appears.
    func activate() {
        guard !injected else { return }
        status = EKEventStore.authorizationStatus(for: .event)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        if status == .notDetermined, !asked {
            requestAccess()
        } else {
            refresh()
        }
    }

    func requestAccess() {
        asked = true
        Task {
            _ = try? await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
            refresh()
        }
    }

    func refresh() {
        guard hasAccess else {
            if !events.isEmpty { events = [] }
            return
        }
        let now = Date()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
            .map { e in
                CalEvent(
                    id: e.eventIdentifier ?? UUID().uuidString,
                    title: (e.title?.isEmpty == false ? e.title! : String(localized: "Untitled")),
                    start: e.startDate,
                    end: e.endDate,
                    allDay: e.isAllDay,
                    color: e.calendar?.color ?? .systemRed
                )
            }
        if found != events { events = found }
    }

    func openCalendarApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func debugInject(_ events: [CalEvent]) {
        injected = true
        status = .fullAccess
        self.events = events
    }
}
