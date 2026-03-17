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
    ///
    /// - Parameters:
    ///   - transcript:    The user's spoken input, as transcribed by Deepgram.
    ///   - memorySummary: Long-term memory injected into the system prompt.
    ///                    Pass `""` when the memory store is not yet available.
    /// - Returns: A markdown-stripped, TTS-ready response string.
    func complete(transcript: String, memorySummary: String = "") async throws -> String {
        let messages = buildMessages(transcript: transcript, memorySummary: memorySummary)
        let raw      = try await callAPI(messages: messages)
        let response = Self.stripMarkdown(raw)

        // Commit to history only after a successful response so that a failed
        // request does not leave a dangling half-turn in the context window.
        history.append(Turn(user: transcript, assistant: response))
        if history.count > Self.maxHistoryTurns {
            history.removeFirst(history.count - Self.maxHistoryTurns)
        }

        return response
    }

    /// Extracts key facts from a raw conversation transcript using a dedicated
    /// extraction prompt. Bypasses `history` entirely — this is a one-shot call
    /// that does not affect the ongoing conversation context.
    ///
    /// - Parameter transcript: Newline-separated "Role: content" lines from the session.
    /// - Returns: 3–6 plain-text bullet points extracted by the model.
    func extractFacts(from transcript: String) async throws -> String {
        let messages: [Message] = [
            Message(
                role:    "system",
                content: "You are a memory extraction assistant. Given a conversation transcript, extract key facts, names, themes, and decisions. Return 3-6 bullet points max, plain text only. Be concise."
            ),
            Message(role: "user", content: transcript)
        ]
        return try await callAPI(messages: messages, maxTokens: 150)
    }

    /// Clears conversation history. Call at the end of each session so the
    /// next session starts fresh (long-term memory is handled by GRDB separately).
    func clearHistory() {
        history.removeAll()
    }

    // MARK: – Message construction

    private func buildMessages(transcript: String, memorySummary: String) -> [Message] {
        var messages: [Message] = []

        // System prompt, optionally extended with the long-term memory summary.
        var systemContent = Self.systemPrompt
        let trimmedMemory = memorySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMemory.isEmpty {
            systemContent += "\n\nWhat you remember about this user:\n\(trimmedMemory)"
        }
        messages.append(Message(role: "system", content: systemContent))

        // Interleaved history: user → assistant → user → assistant …
        for turn in history.suffix(Self.maxHistoryTurns) {
            messages.append(Message(role: "user",      content: turn.user))
            messages.append(Message(role: "assistant", content: turn.assistant))
        }

        // Current utterance — always the final user message.
        messages.append(Message(role: "user", content: transcript))

        return messages
    }

    // MARK: – Network

    private func callAPI(messages: [Message], maxTokens: Int = Self.maxTokens) async throws -> String {
        guard let url = URL(string: Self.endpoint) else {
            preconditionFailure("[GroqService] Invalid endpoint URL")
        }

        var request                 = URLRequest(url: url)
        request.httpMethod          = "POST"
        request.timeoutInterval     = Self.requestTimeout
        request.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")

        let body = GroqRequest(
            model:       Self.model,
            messages:    messages,
            temperature: Self.temperature,
            maxTokens:   maxTokens
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

    // MARK: – Markdown stripping

    /// Removes all markdown syntax from `text`, returning plain prose suitable for TTS.
    ///
    /// Patterns are applied longest-first to prevent partial matches
    /// (e.g. `***bold-italic***` before `**bold**` before `*italic*`).
    static func stripMarkdown(_ text: String) -> String {
        var s = text

        // Fenced code blocks  ```lang\n...\n```  → keep inner text, remove fences.
        s = s.replacingOccurrences(
            of: #"```[^\n]*\n?([\s\S]*?)```"#,
            with: "$1", options: .regularExpression)

        // Inline code  `text`  → text
        s = s.replacingOccurrences(
            of: #"`([^`\n]+)`"#,
            with: "$1", options: .regularExpression)

        // Images  ![alt](url)  → remove entirely
        s = s.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^\)]*\)"#,
            with: "", options: .regularExpression)

        // Links  [text](url)  → text
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^\)]*\)"#,
            with: "$1", options: .regularExpression)

        // Setext headings (underline style)  ===  or  ---  on their own line → remove
        s = s.replacingOccurrences(
            of: #"(?m)^[=\-]{2,}\s*$"#,
            with: "", options: .regularExpression)

        // ATX headings  # H1 / ## H2 / …  → remove hashes
        s = s.replacingOccurrences(
            of: #"(?m)^#{1,6}\s+"#,
            with: "", options: .regularExpression)

        // Horizontal rules  ---  / ***  / ___  on their own line → remove
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*[-*_]{3,}[ \t]*$"#,
            with: "", options: .regularExpression)

        // Bold-italic  ***text***  /  ___text___  (must come before bold/italic)
        s = s.replacingOccurrences(
            of: #"\*{3}(.+?)\*{3}"#,
            with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"_{3}(.+?)_{3}"#,
            with: "$1", options: .regularExpression)

        // Bold  **text**  /  __text__
        s = s.replacingOccurrences(
            of: #"\*{2}(.+?)\*{2}"#,
            with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"_{2}(.+?)_{2}"#,
            with: "$1", options: .regularExpression)

        // Italic  *text*  — require non-whitespace at edges to skip lone asterisks
        // in maths or punctuation ("2 * 3", "…end. *sigh*").
        s = s.replacingOccurrences(
            of: #"\*(\S[^\*\n]*\S|\S)\*"#,
            with: "$1", options: .regularExpression)

        // Italic  _text_  — word-boundary guard avoids stripping snake_case.
        s = s.replacingOccurrences(
            of: #"(?<!\w)_([^_\n]+)_(?!\w)"#,
            with: "$1", options: .regularExpression)

        // Strikethrough  ~~text~~
        s = s.replacingOccurrences(
            of: #"~~(.+?)~~"#,
            with: "$1", options: .regularExpression)

        // Blockquotes  > text  → text
        s = s.replacingOccurrences(
            of: #"(?m)^>+\s?"#,
            with: "", options: .regularExpression)

        // Unordered list markers  -  /  *  /  +  at line start
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*[-*+]\s+"#,
            with: "", options: .regularExpression)

        // Ordered list markers  1.  /  1)  at line start
        s = s.replacingOccurrences(
            of: #"(?m)^[ \t]*\d+[.)]\s+"#,
            with: "", options: .regularExpression)

        // Collapse 3+ consecutive newlines to 2 (preserve paragraph breaks).
        s = s.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – System prompt

    // Verbatim from CLAUDE.md. To change the prompt, update CLAUDE.md first.
    private static let systemPrompt = """
        You are Doki, a personal voice assistant.

        RESPONSE FORMAT
        - This is a voice interface. Responses must be conversational and brief.
        - No bullet points, no markdown, no headers, no lists.
        - 1-3 sentences for most responses. Expand only when explicitly asked.

        CONTEXT & MEMORY
        - Always resolve ambiguous pronouns and follow-up questions against prior conversation context. If the user asks "who won?" after discussing an NBA game, resolve it correctly without asking for clarification.
        - You have a summary of past conversations with this user under "What you remember about this user." Use it to personalize responses and notice patterns over time.
        - Track named entities (people, places, topics) mentioned in the current session for follow-up resolution.

        REASONING
        - For decisions, conflicts, or open-ended thinking: engage, don't just answer. Ask one clarifying question, offer a framework, or reflect something back.
        - For priority triage: help the user find what actually matters today — don't just list everything back at them.
        - For daily check-ins: be proactive, notice patterns, surface relevant things the user hasn't explicitly asked about.

        INTEGRATIONS
        - You have access to the user's calendar and reminders via EventKit. Reference them proactively when relevant.

        TONE
        - Direct, warm, unhurried. Like a smart friend who happens to know a lot.
        - Not robotic. Not overly enthusiastic. Never sycophantic.
        - Your name is Doki.
        """
}

// MARK: – Codable models (file-private)

private struct Message: Encodable {
    let role:    String
    let content: String
}

private struct GroqRequest: Encodable {
    let model:       String
    let messages:    [Message]
    let temperature: Double
    let maxTokens:   Int

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct GroqCompletion: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let content: String?
    }
}
