import Foundation

/// Streams raw Linear16 PCM audio to Deepgram's real-time WebSocket API and
/// returns a final transcript string.
///
/// ## Lifecycle per utterance
/// ```
/// try await deepgram.connect()           // on wake word — open socket early
/// await deepgram.send(chunk)             // ~31×/s during capture
/// let text = try await deepgram.finalise() // signal end, drain results, close
/// ```
///
/// ## Threading
/// `actor` isolation serialises all socket-state mutations. `send()` is designed
/// to be fire-and-forget: it schedules the URLSession write and returns to the
/// caller immediately, costing only the actor-hop overhead (~µs at 31 fps).
///
/// ## No third-party dependencies
/// Uses `URLSessionWebSocketTask` exclusively.
actor DeepgramService {

    // MARK: – Configuration

    private static let wsHost                  = "api.deepgram.com"
    private static let model                   = "nova-2"
    private static let receiveTimeoutSeconds   = 10.0  // max wait after CloseStream

    // MARK: – Error

    enum DeepgramError: Error, LocalizedError {
        case notConnected
        case timeout
        case emptyTranscript
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:          return "WebSocket is not connected"
            case .timeout:               return "Deepgram did not respond within \(Int(receiveTimeoutSeconds))s"
            case .emptyTranscript:       return "Deepgram returned an empty transcript"
            case .serverError(let msg):  return "Deepgram server error: \(msg)"
            }
        }
    }

    // MARK: – State

    private let apiKey: String
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?

    // MARK: – Init

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: – Public API

    /// Opens the WebSocket to Deepgram. Safe to call again — cancels any existing
    /// connection first. Call on wake-word detection so the socket is ready before
    /// the first audio chunk arrives.
    func connect() throws {
        socket?.cancel(with: .normalClosure, reason: nil)

        guard let url = Self.streamingURL() else {
            preconditionFailure("[DeepgramService] Failed to build streaming URL")
        }

        var request = URLRequest(url: url)
        // Header auth is preferred over query-param auth.
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        task.resume()
        socket = task
    }

    /// Sends one audio chunk over the open WebSocket.
    /// Fire-and-forget: per-chunk errors are surfaced when `finalise()` reads the
    /// server's response (the server closes the connection on bad frames).
    func send(_ data: Data) {
        socket?.send(.data(data)) { _ in
            // Intentionally ignored. Connection health is checked in finalise().
        }
    }

    /// Signals end of audio, reads all remaining `is_final` transcript fragments,
    /// and returns the combined transcript string.
    ///
    /// - Throws: `DeepgramError.timeout` if no complete response arrives within 10 s.
    /// - Throws: `DeepgramError.emptyTranscript` if Deepgram returns no speech.
    /// - Throws: `CancellationError` if the calling task is cancelled.
    func finalise() async throws -> String {
        guard let task = socket else { throw DeepgramError.notConnected }

        // Tell Deepgram we're done sending audio. It will flush remaining
        // results and close the connection.
        try await task.send(.string(#"{"type":"CloseStream"}"#))

        // Drain transcript messages with a hard timeout.
        let fragments = try await withTranscriptTimeout { [self] in
            await self.collectFragments(from: task)
        }

        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil

        let transcript = fragments
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        guard !transcript.isEmpty else { throw DeepgramError.emptyTranscript }
        return transcript
    }

    /// Cancels the WebSocket connection immediately. Safe to call at any time,
    /// including when no connection is open.
    func disconnect() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    // MARK: – Receive loop

    /// Reads `Results` messages from the socket until it closes, accumulating
    /// the transcript text from every `is_final: true` frame.
    private func collectFragments(from task: URLSessionWebSocketTask) async -> [String] {
        var fragments: [String] = []

        while true {
            guard !Task.isCancelled else { break }
            do {
                let message = try await task.receive()
                guard case .string(let json) = message else { continue }
                if let text = Self.parseTranscript(from: json), !text.isEmpty {
                    fragments.append(text)
                }
            } catch {
                // Any error here means the connection closed — normal termination.
                break
            }
        }

        return fragments
    }

    // MARK: – Timeout helper

    /// Runs `operation` and races it against a `receiveTimeoutSeconds` watchdog.
    /// Cancels the losing side via task-group cancellation.
    private func withTranscriptTimeout<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { [self] in
                let ns = UInt64(Self.receiveTimeoutSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                throw DeepgramError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw DeepgramError.timeout
            }
            return result
        }
    }

    // MARK: – JSON parsing

    /// Extracts the transcript text from a Deepgram `Results` message.
    /// Returns `nil` for interim results, metadata, or malformed JSON.
    private static func parseTranscript(from json: String) -> String? {
        guard
            let data     = json.data(using: .utf8),
            let response = try? JSONDecoder().decode(DeepgramMessage.self, from: data),
            response.type == "Results",
            response.isFinal == true,
            let text     = response.channel?.alternatives.first?.transcript
        else { return nil }

        return text.isEmpty ? nil : text
    }

    // MARK: – URL builder

    private static func streamingURL() -> URL? {
        var components         = URLComponents()
        components.scheme      = "wss"
        components.host        = wsHost
        components.path        = "/v1/listen"
        components.queryItems  = [
            // Audio format — must match AudioCaptureEngine output exactly.
            URLQueryItem(name: "encoding",       value: "linear16"),
            URLQueryItem(name: "sample_rate",    value: "16000"),
            URLQueryItem(name: "channels",       value: "1"),
            // Model and language.
            URLQueryItem(name: "model",          value: model),
            URLQueryItem(name: "language",       value: "en-US"),
            // Formatting — punctuation and smart formatting (numbers, dates, etc.).
            URLQueryItem(name: "punctuate",      value: "true"),
            URLQueryItem(name: "smart_format",   value: "true"),
            // Only deliver final transcripts — no interim partials.
            // Keeps the receive loop simple; we don't need live word-by-word results.
            URLQueryItem(name: "interim_results", value: "false"),
        ]
        return components.url
    }
}

// MARK: – Deepgram response model

/// Minimal decoding of Deepgram's `Results` event.
/// Full schema: https://developers.deepgram.com/reference/streaming
private struct DeepgramMessage: Decodable {

    let type:    String
    let isFinal: Bool?
    let channel: Channel?

    struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    struct Alternative: Decodable {
        let transcript: String
        let confidence: Double?
    }

    enum CodingKeys: String, CodingKey {
        case type
        case isFinal  = "is_final"
        case channel
    }
}
