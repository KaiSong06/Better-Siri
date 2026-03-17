import EventKit
import Foundation

/// Reads and writes the user's calendar and reminders via EventKit.
///
/// ## Permissions
/// EventKit requires separate authorisation for calendars and reminders.
/// Call `requestPermission()` once at app start. All methods degrade gracefully
/// when access is denied — read returns `""`, writes throw `CalendarError.permissionDenied`.
///
/// ## Info.plist keys required
/// iOS 17+: NSCalendarsFullAccessUsageDescription, NSRemindersFullAccessUsageDescription
/// iOS 16:  NSCalendarsUsageDescription, NSRemindersUsageDescription
///
/// ## Threading
/// `actor` isolation serialises access to the auth-state flags. EventKit's
/// `EKEventStore` is internally thread-safe and can be shared across calls.
actor CalendarService {

    // MARK: – Errors

    enum CalendarError: Error, LocalizedError {
        case permissionDenied
        case noDefaultCalendar
        case saveFailed(Error)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:  return "Calendar or Reminders access is not authorised"
            case .noDefaultCalendar: return "No writable calendar found on this device"
            case .saveFailed(let e): return "Save failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: – State

    private let store = EKEventStore()
    private var calendarAuthorized = false
    private var reminderAuthorized = false

    // MARK: – Permissions

    /// Requests full access to both Calendars and Reminders.
    /// Safe to call multiple times — EventKit caches the authorisation decision.
    func requestPermission() async {
        if #available(iOS 17, *) {
            calendarAuthorized = (try? await store.requestFullAccessToEvents())    ?? false
            reminderAuthorized = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            calendarAuthorized = await withCheckedContinuation { cont in
                store.requestAccess(to: .event)    { granted, _ in cont.resume(returning: granted) }
            }
            reminderAuthorized = await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { granted, _ in cont.resume(returning: granted) }
            }
        }
        print("[CalendarService] Calendar: \(calendarAuthorized ? "✅" : "❌")  Reminders: \(reminderAuthorized ? "✅" : "❌")")
    }

    // MARK: – Read

    /// Returns a plain-English summary of upcoming calendar events, ready to
    /// inject directly into the Groq system prompt.
    ///
    /// Returns `""` when there are no events or access is denied — the LLM
    /// simply won't reference the calendar in those cases.
    ///
    /// Example output:
    /// "The user has 3 upcoming events in the next 7 days: dentist appointment
    ///  tomorrow at 2 PM, team standup on Wednesday at 9 AM, dinner with Alice
    ///  on Friday at 7 PM."
    ///
    /// - Parameter days: Look-ahead window (default 7).
    func getUpcomingEvents(days: Int = 7) -> String {
        guard calendarAuthorized else { return "" }

        let now  = Date()
        let end  = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else { return "" }

        // Cap at 8 events so we never flood the context window.
        let cap       = min(events.count, 8)
        let overflow  = events.count - cap
        let listed    = events.prefix(cap).map { Self.describe($0) }.joined(separator: ", ")

        var summary = "The user has \(events.count) upcoming event\(events.count == 1 ? "" : "s")"
            + " in the next \(days) day\(days == 1 ? "" : "s"): \(listed)"
        if overflow > 0 { summary += ", and \(overflow) more" }
        return summary + "."
    }

    // MARK: – Write

    /// Creates a new event in the user's default calendar.
    ///
    /// The event spans one hour from `date`. Pass `notes` for location,
    /// agenda, or any detail the user mentioned.
    ///
    /// - Throws: `CalendarError.permissionDenied` if access was not granted,
    ///           `CalendarError.noDefaultCalendar` if no writable calendar exists,
    ///           `CalendarError.saveFailed` on EventKit errors.
    func addEvent(title: String, date: Date, notes: String? = nil) throws {
        guard calendarAuthorized else { throw CalendarError.permissionDenied }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CalendarError.noDefaultCalendar
        }

        let event       = EKEvent(eventStore: store)
        event.title     = title
        event.startDate = date
        event.endDate   = Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date
        event.notes     = notes
        event.calendar  = calendar

        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarError.saveFailed(error)
        }
    }

    /// Creates a new reminder in the user's default reminder list.
    ///
    /// If `dueDate` is provided the reminder will also schedule an alert at
    /// that time. Pass `nil` for a floating (date-free) reminder.
    ///
    /// - Throws: `CalendarError.permissionDenied` if access was not granted,
    ///           `CalendarError.noDefaultCalendar` if no default list exists,
    ///           `CalendarError.saveFailed` on EventKit errors.
    func addReminder(title: String, dueDate: Date? = nil) throws {
        guard reminderAuthorized else { throw CalendarError.permissionDenied }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw CalendarError.noDefaultCalendar
        }

        let reminder      = EKReminder(eventStore: store)
        reminder.title    = title
        reminder.calendar = list

        if let due = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw CalendarError.saveFailed(error)
        }
    }

    // MARK: – Natural-language formatting

    /// "dentist appointment tomorrow at 2 PM"
    /// "all-hands meeting all day on Friday"
    private static func describe(_ event: EKEvent) -> String {
        let title = event.title ?? "untitled event"
        if event.isAllDay {
            return "\(title) all day on \(dayLabel(event.startDate))"
        } else {
            return "\(title) on \(dayLabel(event.startDate)) at \(timeLabel(event.startDate))"
        }
    }

    /// "today", "tomorrow", "Wednesday", "March 25"
    private static func dayLabel(_ date: Date) -> String {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let day   = cal.startOfDay(for: date)
        let diff  = cal.dateComponents([.day], from: today, to: day).day ?? 0

        switch diff {
        case 0:
            return "today"
        case 1:
            return "tomorrow"
        case 2...6:
            let f = DateFormatter()
            f.dateFormat = "EEEE"   // "Wednesday"
            return f.string(from: date)
        default:
            let f = DateFormatter()
            f.dateFormat = "MMMM d" // "March 25"
            return f.string(from: date)
        }
    }

    /// "2 PM", "2:30 PM"
    private static func timeLabel(_ date: Date) -> String {
        let mins = Calendar.current.component(.minute, from: date)
        let f    = DateFormatter()
        f.dateFormat = mins == 0 ? "h a" : "h:mm a"
        return f.string(from: date)
    }
}
