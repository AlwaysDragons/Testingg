import EventKit
import Foundation
import Observation

/// Calendar events for the Today timeline (EventKit, on-device only). You choose which calendars show.
/// Writes happen only after you approve a plan (time blocking).
@Observable
@MainActor
final class CalendarService {
    @ObservationIgnored private let eventStore = EKEventStore()
    private(set) var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    private(set) var calendars: [EKCalendar] = []
    private(set) var today: [CalEvent] = []
    /// Calendar ids hidden from Today (all calendars show by default).
    private(set) var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Keys.hidden) ?? [])
    /// Where approved time blocks are written (default: the system default calendar).
    var blockCalendarId: String? = UserDefaults.standard.string(forKey: Keys.blocks) {
        didSet { UserDefaults.standard.set(blockCalendarId, forKey: Keys.blocks) }
    }
    var lastError: String?

    private enum Keys {
        static let hidden = "calendar.hidden"
        static let blocks = "calendar.blocks"
    }

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func requestAccess() async -> Bool {
        do { authorized = try await eventStore.requestFullAccessToEvents() } catch { authorized = false; lastError = error.localizedDescription }
        reload()
        return authorized
    }

    func reload(day: Date = Date()) {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard authorized else { calendars = []; today = []; return }
        calendars = eventStore.calendars(for: .event).sorted { $0.title < $1.title }
        let shown = calendars.filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { today = []; return }
        let start = Calendar.current.startOfDay(for: day)
        let predicate = eventStore.predicateForEvents(withStart: start, end: start.addingTimeInterval(86_400), calendars: shown)
        today = eventStore.events(matching: predicate).map { e in
            CalEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Event", start: e.startDate, end: e.endDate,
                     isAllDay: e.isAllDay, calendarTitle: e.calendar?.title ?? "", colorHex: nil)
        }
    }

    func isShown(_ c: EKCalendar) -> Bool { !hidden.contains(c.calendarIdentifier) }

    func setShown(_ c: EKCalendar, _ shown: Bool) {
        if shown { hidden.remove(c.calendarIdentifier) } else { hidden.insert(c.calendarIdentifier) }
        UserDefaults.standard.set(Array(hidden), forKey: Keys.hidden)
        reload()
    }

    var writableCalendars: [EKCalendar] { calendars.filter(\.allowsContentModifications) }

    /// Writes approved time blocks as events. Returns how many were added.
    @discardableResult
    func add(blocks: [TimeBlockPlan.Block]) -> Int {
        guard authorized else { return 0 }
        let target = blockCalendarId.flatMap { eventStore.calendar(withIdentifier: $0) } ?? eventStore.defaultCalendarForNewEvents
        var added = 0
        for b in blocks {
            guard let start = LifeCoding.parse(b.start), let end = LifeCoding.parse(b.end), end > start else { continue }
            let e = EKEvent(eventStore: eventStore)
            e.title = b.title
            e.startDate = start
            e.endDate = end
            e.calendar = target
            e.notes = "Planned with Forge"
            do { try eventStore.save(e, span: .thisEvent, commit: false); added += 1 } catch { lastError = error.localizedDescription }
        }
        try? eventStore.commit()
        reload()
        return added
    }
}

/// A drafted day plan (time blocks), returned by the `plan_day` task.
struct TimeBlockPlan: Codable, Equatable, Sendable {
    struct Block: Codable, Equatable, Sendable, Hashable { var title: String; var start: String; var end: String; var itemId: String? }
    var blocks: [Block]
    var note: String?
}
