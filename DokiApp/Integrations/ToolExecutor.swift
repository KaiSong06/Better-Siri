import Foundation

/// A parsed tool call returned by Groq when it decides to invoke a function.
struct ParsedToolCall {
    let id:        String           // tool_call_id — echoed back in the tool-role message
    let name:      String           // "add_calendar_event" | "add_reminder" | "call_contact" | …
    let arguments: [String: Any]    // decoded from the raw JSON string in tool_calls[n].function.arguments
}

/// Dispatches tool calls from Groq to the appropriate service.
///
/// ## Design
/// Value type — no mutable state of its own. All async work is delegated to
/// actor-isolated services (`CalendarService`, `ContactService`) or the
/// `@MainActor`-isolated `MessageHandler`. Never throws: errors are captured
/// as plain strings so Groq can speak a natural-language apology to the user.
struct ToolExecutor {

    private let calendar:       CalendarService
    private let contacts:       ContactService
    private let callHandler:    CallHandler
    private let messageHandler: MessageHandler

    init(calendar: CalendarService, contacts: ContactService, messageHandler: MessageHandler) {
        self.calendar       = calendar
        self.contacts       = contacts
        self.callHandler    = CallHandler(contacts: contacts)
        self.messageHandler = messageHandler
    }

    /// Executes every tool call and returns one `(id, result)` pair per call.
    /// The `result` string is fed back to Groq as a `tool`-role message so it
    /// can produce a spoken confirmation or error.
    func execute(_ calls: [ParsedToolCall]) async -> [(id: String, result: String)] {
        var results: [(id: String, result: String)] = []
        for call in calls {
            let result = await dispatch(call)
            results.append((id: call.id, result: result))
        }
        return results
    }

    // MARK: – Dispatch

    private func dispatch(_ call: ParsedToolCall) async -> String {
        print("[ToolExecutor] Dispatching: \(call.name) args=\(call.arguments)")
        switch call.name {
        case "add_calendar_event": return await addCalendarEvent(call.arguments)
        case "add_reminder":       return await addReminder(call.arguments)
        case "call_contact":       return await callContact(call.arguments)
        case "prepare_message":    return await prepareMessage(call.arguments)
        case "confirm_message":    return await confirmMessage()
        case "cancel_message":     return await cancelMessage()
        default:                   return "Unknown tool: \(call.name)"
        }
    }

    // MARK: – Calendar tools

    private func addCalendarEvent(_ args: [String: Any]) async -> String {
        guard let title = args["title"] as? String else {
            return "Could not add event: missing title."
        }
        guard let startTimeStr = args["start_time"] as? String,
              let date = parseISO8601(startTimeStr) else {
            return "Could not add event: missing or invalid start time. Please try again with a specific date and time."
        }
        let notes = args["notes"] as? String

        do {
            try await calendar.addEvent(title: title, date: date, notes: notes)
            return "Event added: \(title) on \(formatConfirmation(date))."
        } catch CalendarService.CalendarError.permissionDenied {
            return "Calendar access is not authorised. Please grant permission in Settings."
        } catch CalendarService.CalendarError.noDefaultCalendar {
            return "No default calendar found on this device."
        } catch {
            return "Failed to add event: \(error.localizedDescription)"
        }
    }

    private func addReminder(_ args: [String: Any]) async -> String {
        guard let title = args["title"] as? String else {
            return "Could not add reminder: missing title."
        }
        let dueDate: Date? = (args["due_time"] as? String).flatMap { parseISO8601($0) }

        do {
            try await calendar.addReminder(title: title, dueDate: dueDate)
            if let due = dueDate {
                return "Reminder added: \(title), due \(formatConfirmation(due))."
            } else {
                return "Reminder added: \(title)."
            }
        } catch CalendarService.CalendarError.permissionDenied {
            return "Reminders access is not authorised. Please grant permission in Settings."
        } catch CalendarService.CalendarError.noDefaultCalendar {
            return "No default reminders list found on this device."
        } catch {
            return "Failed to add reminder: \(error.localizedDescription)"
        }
    }

    // MARK: – Calling tool

    private func callContact(_ args: [String: Any]) async -> String {
        let name   = args["contact_name"] as? String
        let number = args["phone_number"]  as? String
        return await callHandler.call(name: name, number: number)
    }

    // MARK: – Messaging tools

    private func prepareMessage(_ args: [String: Any]) async -> String {
        guard let body = args["body"] as? String, !body.isEmpty else {
            return "Could not prepare message: no message body provided."
        }
        let name   = args["contact_name"] as? String
        let number = args["phone_number"]  as? String
        return await messageHandler.prepare(name: name, number: number, body: body)
    }

    private func confirmMessage() async -> String {
        await messageHandler.confirm()
    }

    private func cancelMessage() async -> String {
        await messageHandler.cancel()
    }

    // MARK: – Date parsing

    /// Parses an ISO 8601 string from the model into a `Date`.
    /// Tries several format variants in order: with timezone offset (preferred),
    /// with fractional seconds, bare datetime (assumes local timezone), date-only.
    private func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()

        // With timezone offset — e.g. "2026-03-18T12:00:00-05:00"
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: string) { return date }

        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: string) { return date }

        // No timezone — model returned bare datetime, interpret as local time
        let df = DateFormatter()
        df.timeZone = TimeZone.current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let date = df.date(from: string) { return date }
        }

        return nil
    }

    /// Short human-readable date for the spoken confirmation, e.g. "March 20 at 3 PM".
    private func formatConfirmation(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d 'at' h:mm a"
        let s = f.string(from: date)
        // Drop ":00" for on-the-hour times
        return s.replacingOccurrences(of: ":00 ", with: " ")
    }
}
