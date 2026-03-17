import Foundation

/// Summarises a completed session by calling Groq with the extraction prompt
/// and persisting the result to `MemoryStore`.
///
/// ## Usage
/// ```swift
/// let summariser = MemorySummariser(groq: groqService, store: memoryStore)
/// await summariser.summarise(sessionID: sessionID)
/// ```
///
/// ## Threading
/// Value type, no isolation. Delegates all async work to the `GroqService`
/// and `MemoryStore` actors via `await`. Safe to call from any context.
struct MemorySummariser {

    private let groq:  GroqService
    private let store: MemoryStore

    init(groq: GroqService, store: MemoryStore) {
        self.groq  = groq
        self.store = store
    }

    /// Fetches all turns for `sessionID`, asks Groq to extract key facts,
    /// and saves the resulting bullet-point summary as a `SessionSummary`.
    ///
    /// Silently no-ops when the session has fewer than 2 turns (nothing worth
    /// summarising) or when either service call fails — memory loss is
    /// preferable to crashing the pipeline on session end.
    func summarise(sessionID: String) async {
        do {
            let turns = try await store.getSessionTurns(sessionID: sessionID)
            guard turns.count >= 2 else { return }

            let transcript = turns
                .map { "\($0.role == "user" ? "User" : "Doki"): \($0.content)" }
                .joined(separator: "\n")

            let facts = try await groq.extractFacts(from: transcript)
            try await store.saveSessionSummary(facts)
            print("[MemorySummariser] Saved summary for session \(sessionID.prefix(8))…")
        } catch {
            print("[MemorySummariser] Summarisation failed (non-fatal): \(error.localizedDescription)")
        }
    }
}
