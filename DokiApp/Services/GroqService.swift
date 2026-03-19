import Foundation

/// Calls the Groq chat completions API with Llama 3 and returns a clean,
/// markdown-free response string ready for text-to-speech.
///
/// ## Request composition
/// Every call assembles:
///   1. The system prompt (verbatim from CLAUDE.md) + optional memory summary
///   2. The last `maxHistoryTurns` completed exchanges (user → assistant pairs)
///   3. The current user utterance
///
/// ## Function calling
/// `completeWithToolSupport` extends the standard flow with a two-turn loop:
///   1. Send messages + tool definitions to Groq
///   2. If Groq returns tool_calls, execute them via `ToolExecutor`
///   3. Feed results back and call Groq again for the final spoken response
///
/// ## Threading
/// `actor` isolation serialises access to the mutable `history` array and
/// prevents a second request from starting before the first has committed
/// its turn to history.
actor GroqService {

    // MARK: – Configuration

    private static let endpoint        = "https://api.groq.com/openai/v1/chat/completions"
    private static let model           = "llama-3.3-70b-versatile"
    private static let maxHistoryTurns = 10     // = up to 20 messages (user+assistant per turn)
    private static let maxTokens       = 300    // ample for 1–3 spoken sentences
    private static let temperature     = 0.7
    private static let requestTimeout  = 15.0   // seconds; Groq typically responds in <1 s

    // MARK: – Errors

    enum GroqError: Error, LocalizedError {
        case httpError(Int, String)
        case emptyResponse
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let body):
                return "Groq HTTP \(code): \(body.prefix(200))"
            case .emptyResponse:
                return "Groq returned an empty response"
            case .rateLimited:
                return "Groq rate limit hit — retry after a moment"
            }
        }
    }

    // MARK: – State

    private let apiKey: String
    private let session = URLSession(configuration: .default)

    /// Completed conversation turns, newest last.
    private var history: [Turn] = []

    /// One completed exchange: what the user said and what Doki replied.
    struct Turn {
        let user:      String
        let assistant: String
    }

    // MARK: – Init

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: – Public API

    /// Sends one conversation turn to Groq and returns a clean response.
    /// No tool support — used for simple turns where function calling is not needed.
    func complete(transcript: String, memorySummary: String = "", calendarContext: String = "") async throws -> String {
        let messages = buildMessages(transcript: transcript, memorySummary: memorySummary, calendarContext: calendarContext)
        let raw      = try await callAPI(messages: messages)
        let response = Self.stripMarkdown(raw)

        history.append(Turn(user: transcript, assistant: response))
        if history.count > Self.maxHistoryTurns {
            history.removeFirst(history.count - Self.maxHistoryTurns)
        }

        return response
    }

    /// Sends one conversation turn to Groq with tool definitions for calendar and
    /// reminders. If Groq calls a tool, executes it via `executor` then calls Groq
    /// again for the final spoken response. Commits one turn to history either way.
    func completeWithToolSupport(
        transcript:      String,
        memorySummary:   String = "",
        calendarContext: String = "",
        executor:        ToolExecutor
    ) async throws -> String {
        var messages = buildMessages(
            transcript:      transcript,
            memorySummary:   memorySummary,
            calendarContext: calendarContext
        )

        // ── First call: with tools ─────────────────────────────────────────────
        let choice = try await callAPIWithTools(messages: messages)

        print("[GroqService] finishReason=\(choice.finishReason ?? "nil") toolCalls=\(choice.message.toolCalls?.count ?? 0)")

        let response: String

        if choice.finishReason == "tool_calls",
           let toolCalls = choice.message.toolCalls, !toolCalls.isEmpty {

            // ── Parse tool calls ───────────────────────────────────────────────
            let parsed = toolCalls.compactMap { tc -> ParsedToolCall? in
                print("[GroqService] Tool call: \(tc.function.name) args=\(tc.function.arguments)")
                guard let data = tc.function.arguments.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return ParsedToolCall(id: tc.id, name: tc.function.name, arguments: args)
            }

            // ── Append assistant message with tool_calls to context ────────────
            messages.append(Message(role: "assistant", content: nil, toolCalls: toolCalls))

            // ── Execute tools ──────────────────────────────────────────────────
            let results = await executor.execute(parsed)

            // ── Append tool results ────────────────────────────────────────────
            for result in results {
                messages.append(Message(role: "tool", content: result.result, toolCallId: result.id))
            }

            // ── Second call: plain, no tools — get the spoken response ─────────
            let raw = try await callAPI(messages: messages)
            response = Self.stripMarkdown(raw)

        } else {
            // No tool call — treat as a normal response.
            guard let content = choice.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GroqError.emptyResponse
            }
            response = Self.stripMarkdown(content)
        }

        history.append(Turn(user: transcript, assistant: response))
        if history.count > Self.maxHistoryTurns {
            history.removeFirst(history.count - Self.maxHistoryTurns)
        }

        return response
    }

    /// Extracts key facts from a raw conversation transcript using a dedicated
    /// extraction prompt. Bypasses `history` entirely.
    func extractFacts(from transcript: String) async throws -> String {
        let messages: [Message] = [
            Message(role: "system", content: "You are a memory extraction assistant. Given a conversation transcript, extract key facts, names, themes, and decisions. Return 3-6 bullet points max, plain text only. Be concise."),
            Message(role: "user",   content: transcript)
        ]
        return try await callAPI(messages: messages, maxTokens: 150)
    }

    /// Clears conversation history. Call at the end of each session.
    func clearHistory() {
        history.removeAll()
    }

    // MARK: – Message construction

    private func buildMessages(transcript: String, memorySummary: String, calendarContext: String) -> [Message] {
        var messages: [Message] = []

        // Inject current local date/time so the model can resolve relative expressions
        // like "today at noon" or "tomorrow at 3pm" into correct ISO 8601 values.
        // Use local timezone so "today" matches the user's calendar, not UTC.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        dateFormatter.timeZone = TimeZone.current
        let nowString = dateFormatter.string(from: Date())

        var systemContent = Self.systemPrompt + "\n\nCurrent local date and time: \(nowString). All tool call datetimes must use this same timezone offset."
        let trimmedMemory = memorySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMemory.isEmpty {
            systemContent += "\n\nWhat you remember about this user:\n\(trimmedMemory)"
        }
        let trimmedCalendar = calendarContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCalendar.isEmpty {
            systemContent += "\n\nCalendar context:\n\(trimmedCalendar)"
        }
        messages.append(Message(role: "system", content: systemContent))

        for turn in history.suffix(Self.maxHistoryTurns) {
            messages.append(Message(role: "user",      content: turn.user))
            messages.append(Message(role: "assistant", content: turn.assistant))
        }

        messages.append(Message(role: "user", content: transcript))
        return messages
    }

    // MARK: – Network

    /// Plain chat completions call — no tools. Used for normal turns and the
    /// second pass after tool execution.
    private func callAPI(messages: [Message], maxTokens: Int = 300) async throws -> String {
        guard let url = URL(string: Self.endpoint) else {
            preconditionFailure("[GroqService] Invalid endpoint URL")
        }

        var request             = URLRequest(url: url)
        request.httpMethod      = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")

        let body = GroqRequest(
            model:       Self.model,
            messages:    messages,
            temperature: Self.temperature,
            maxTokens:   maxTokens,
            tools:       nil,
            toolChoice:  nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: request)

        guard let http = urlResponse as? HTTPURLResponse else {
            throw GroqError.httpError(0, "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 { throw GroqError.rateLimited }
            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
            throw GroqError.httpError(http.statusCode, body)
        }

        let completion = try JSONDecoder().decode(GroqCompletion.self, from: data)
        guard let content = completion.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GroqError.emptyResponse
        }

        return content
    }

    /// Chat completions call with tool definitions. Returns the raw `Choice` so
    /// the caller can inspect `finishReason` and `toolCalls`.
    private func callAPIWithTools(messages: [Message], maxTokens: Int = 300) async throws -> GroqCompletion.Choice {
        guard let url = URL(string: Self.endpoint) else {
            preconditionFailure("[GroqService] Invalid endpoint URL")
        }

        var request             = URLRequest(url: url)
        request.httpMethod      = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")

        let body = GroqRequest(
            model:       Self.model,
            messages:    messages,
            temperature: Self.temperature,
            maxTokens:   maxTokens,
            tools:       Self.tools,
            toolChoice:  "auto"
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: request)

        guard let http = urlResponse as? HTTPURLResponse else {
            throw GroqError.httpError(0, "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 { throw GroqError.rateLimited }
            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
            throw GroqError.httpError(http.statusCode, body)
        }

        let completion = try JSONDecoder().decode(GroqCompletion.self, from: data)
        guard let choice = completion.choices.first else {
            throw GroqError.emptyResponse
        }
        return choice
    }

    // MARK: – Tool definitions

    private static let tools: [ToolDefinition] = [
        ToolDefinition(
            type: "function",
            function: ToolDefinition.FunctionDef(
                name: "add_calendar_event",
                description: "Use this when the user wants to schedule an appointment, meeting, or event on a specific date and time. Adds it to the iOS Calendar app.",
                parameters: ToolParameters(
                    type: "object",
                    properties: [
                        "title":      PropertySchema(type: "string", description: "Title of the event"),
                        "start_time": PropertySchema(type: "string", description: "ISO 8601 datetime, e.g. 2025-03-20T15:00:00. Interpret relative expressions like 'tomorrow at 3pm' against today's date."),
                        "notes":      PropertySchema(type: "string", description: "Optional notes, location, or agenda for the event")
                    ],
                    required: ["title", "start_time"]
                )
            )
        ),
        ToolDefinition(
            type: "function",
            function: ToolDefinition.FunctionDef(
                name: "add_reminder",
                description: "Use this when the user wants to be reminded of something. Adds it to the iOS Reminders app. Due date is optional.",
                parameters: ToolParameters(
                    type: "object",
                    properties: [
                        "title":    PropertySchema(type: "string", description: "What to be reminded about"),
                        "due_time": PropertySchema(type: "string", description: "Optional ISO 8601 datetime for when the reminder should fire")
                    ],
                    required: ["title"]
                )
            )
        ),
        ToolDefinition(
            type: "function",
            function: ToolDefinition.FunctionDef(
                name: "call_contact",
                description: "Places a phone call to a contact by name or literal phone number. Use when the user says 'call', 'ring', 'phone', or 'dial' someone.",
                parameters: ToolParameters(
                    type: "object",
                    properties: [
                        "contact_name": PropertySchema(type: "string", description: "Full or partial display name of the contact to call"),
                        "phone_number": PropertySchema(type: "string", description: "Literal phone number to dial when no contact name is given")
                    ],
                    required: []
                )
            )
        ),
        ToolDefinition(
            type: "function",
            function: ToolDefinition.FunctionDef(
                name: "prepare_message",
                description: "Prepares a text message to a contact. Call this first, then ask the user to confirm or cancel before opening the compose sheet. Use when the user says 'text', 'message', or 'send a message' to someone.",
                parameters: ToolParameters(
                    type: "object",
                    properties: [
                        "contact_name": PropertySchema(type: "string", description: "Display name of the recipient contact"),
                        "phone_number": PropertySchema(type: "string", description: "Literal phone number when no contact name is given"),
                        "body":         PropertySchema(type: "string", description: "The exact message body to send")
                    ],
                    required: ["body"]
                )
            )
        ),
        ToolDefinition(
            type: "function",
            function: ToolDefinition.FunctionDef(
                name: "confirm_message",
                description: "Opens the pre-filled message compose sheet after the user confirms they want to send the pending message.",
                parameters: ToolParameters(
                    type: "object",
                    properties: [:],
                    required: []
                )
            )
        ),
        ToolDefinition(
            type: "function",
            function: ToolDefinition.FunctionDef(
                name: "cancel_message",
                description: "Cancels the pending message and dismisses any open compose sheet when the user says no or cancel.",
                parameters: ToolParameters(
                    type: "object",
                    properties: [:],
                    required: []
                )
            )
        )
    ]

    // MARK: – Markdown stripping

    static func stripMarkdown(_ text: String) -> String {
        var s = text

        s = s.replacingOccurrences(of: #"```[^\n]*\n?([\s\S]*?)```"#,          with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`\n]+)`"#,                        with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^\)]*\)"#,              with: "",     options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]*\)"#,             with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[=\-]{2,}\s*$"#,                with: "",     options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#,                    with: "",     options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*[-*_]{3,}[ \t]*$"#,      with: "",     options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*{3}(.+?)\*{3}"#,                   with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"_{3}(.+?)_{3}"#,                     with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*{2}(.+?)\*{2}"#,                   with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"_{2}(.+?)_{2}"#,                     with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*(\S[^\*\n]*\S|\S)\*"#,             with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\w)_([^_\n]+)_(?!\w)"#,          with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~(.+?)~~"#,                          with: "$1",   options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^>+\s?"#,                        with: "",     options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*[-*+]\s+"#,               with: "",     options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*\d+[.)]\s+"#,             with: "",     options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#,                             with: "\n\n", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – System prompt

    private static let systemPrompt = """
        You are Doki, a personal voice assistant.

        RESPONSE FORMAT
        - This is a voice interface. Responses must be conversational and brief.
        - No bullet points, no markdown, no headers, no lists.
        - 1-2 sentences for most responses. Expand only when explicitly asked.

        CONTEXT & MEMORY
        - Always resolve ambiguous pronouns and follow-up questions against prior conversation context. If the user asks "who won?" after discussing an NBA game, resolve it correctly without asking for clarification.
        - You have a summary of past conversations with this user under "What you remember about this user." Use it to personalize responses and notice patterns over time.
        - Track named entities (people, places, topics) mentioned in the current session for follow-up resolution.
        - Only use context and memory if it is deemed relevant to the current conversation

        REASONING
        - For most requests, just answer — do not ask follow-up questions.
        - Only ask a follow-up when you genuinely cannot fulfil the request without more information (e.g. the user says "add a meeting" with no time at all). Keep it to one short question.
        - For decisions or open-ended thinking: offer a perspective or framework, do not ask multiple questions.
        - For daily check-ins: surface one relevant observation, do not pepper the user with questions.

        INTEGRATIONS
        - You have access to the user's calendar and reminders via EventKit. Use the add_calendar_event tool to add events to the Calendar app and add_reminder to add items to the Reminders app. Reference the user's upcoming events proactively when relevant.
        - You can place phone calls with call_contact. Use it when the user says "call", "ring", "phone", or "dial" someone.
        - You can send text messages in two steps: first call prepare_message to resolve the recipient and queue the message, then ask the user "Should I send it?" (ending with a question mark). If they confirm, call confirm_message to open the compose sheet. If they cancel, call cancel_message. Always confirm before sending.

        TONE
        - Direct, warm, unhurried. Like a smart friend who happens to know a lot.
        - Not robotic. Not overly enthusiastic. Never sycophantic.
        - Your name is Doki.
        """
}

// MARK: – Codable models

private struct Message: Encodable {
    let role:       String
    let content:    String?
    let toolCallId: String?
    let toolCalls:  [GroqCompletion.ToolCallResponse]?

    /// Convenience init for the common case — plain role + content message.
    init(role: String, content: String) {
        self.role       = role
        self.content    = content
        self.toolCallId = nil
        self.toolCalls  = nil
    }

    /// Full init for tool-role and assistant-with-tool-calls messages.
    init(role: String, content: String?, toolCallId: String? = nil, toolCalls: [GroqCompletion.ToolCallResponse]? = nil) {
        self.role       = role
        self.content    = content
        self.toolCallId = toolCallId
        self.toolCalls  = toolCalls
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if let content    { try c.encode(content,    forKey: .content) }
        if let toolCallId { try c.encode(toolCallId, forKey: .toolCallId) }
        if let toolCalls  { try c.encode(toolCalls,  forKey: .toolCalls) }
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCallId = "tool_call_id"
        case toolCalls  = "tool_calls"
    }
}

private struct GroqRequest: Encodable {
    let model:       String
    let messages:    [Message]
    let temperature: Double
    let maxTokens:   Int
    let tools:       [ToolDefinition]?
    let toolChoice:  String?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, tools
        case maxTokens  = "max_tokens"
        case toolChoice = "tool_choice"
    }
}

private struct GroqCompletion: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message:      ResponseMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct ResponseMessage: Decodable {
        let content:   String?
        let toolCalls: [ToolCallResponse]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallResponse: Codable {
        let id:       String
        let type:     String
        let function: FunctionCall

        struct FunctionCall: Codable {
            let name:      String
            let arguments: String   // raw JSON string from Groq
        }
    }
}

// MARK: – Tool definition Codable types

private struct ToolDefinition: Encodable {
    let type:     String
    let function: FunctionDef

    struct FunctionDef: Encodable {
        let name:        String
        let description: String
        let parameters:  ToolParameters
    }
}

private struct ToolParameters: Encodable {
    let type:       String
    let properties: [String: PropertySchema]
    let required:   [String]
}

private struct PropertySchema: Encodable {
    let type:        String
    let description: String
}
