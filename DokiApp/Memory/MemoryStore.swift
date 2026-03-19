import Foundation
import GRDB

// MARK: – Record types

/// One message in a conversation — either a user utterance or Doki's response.
struct ConversationTurn: Codable, FetchableRecord, PersistableRecord {
    var id:        Int64?
    var sessionID: String
    var role:      String   // "user" | "assistant"
    var content:   String
    var timestamp: Double   // Unix epoch (Date().timeIntervalSince1970)

    static let databaseTableName = "conversation_turn"

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case role, content, timestamp
    }
}

/// A compressed summary of one past session, extracted by Groq at session end.
struct SessionSummary: Codable, FetchableRecord, PersistableRecord {
    var id:          Int64?
    var summaryText: String
    var timestamp:   Double   // Unix epoch

    static let databaseTableName = "session_summary"

    enum CodingKeys: String, CodingKey {
        case id
        case summaryText = "summary_text"
        case timestamp
    }
}

// MARK: – MemoryStore

/// Persistent storage for conversation turns and session summaries.
///
/// ## Storage
/// SQLite database at `<Documents>/doki_memory.sqlite`, accessed via
/// GRDB `DatabaseQueue` (serial, WAL mode). All reads and writes are
/// synchronous within the actor; SQLite operations are sub-millisecond
/// for the data volumes Doki produces.
///
/// ## Threading
/// `actor` isolation serialises all database access. Callers use
/// `try await` to hop onto the actor's executor.
actor MemoryStore {

    private let db: DatabaseQueue

    // MARK: – Init

    init() throws {
        let dir = try FileManager.default.url(
            for:              .documentDirectory,
            in:               .userDomainMask,
            appropriateFor:   nil,
            create:           true
        )
        let path = dir.appendingPathComponent("doki_memory.sqlite").path
        db = try DatabaseQueue(path: path)
        try Self.applyMigrations(db)
    }

    // MARK: – Schema

    private static func applyMigrations(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "conversation_turn") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).notNull().indexed()
                t.column("role",       .text).notNull()
                t.column("content",    .text).notNull()
                t.column("timestamp",  .double).notNull()
            }
            try db.create(table: "session_summary") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("summary_text", .text).notNull()
                t.column("timestamp",    .double).notNull()
            }
        }

        try migrator.migrate(db)
    }

    // MARK: – ConversationTurn

    /// Persists one message. Call once for the user utterance and once for
    /// Doki's response after every successful exchange.
    func saveTurn(sessionID: String, role: String, content: String) throws {
        var turn = ConversationTurn(
            id:        nil,
            sessionID: sessionID,
            role:      role,
            content:   content,
            timestamp: Date().timeIntervalSince1970
        )
        try db.write { db in try turn.insert(db) }
    }

    /// Returns the `n` most recent individual messages across all sessions,
    /// ordered oldest-first.
    ///
    /// Note: each user+assistant exchange produces 2 rows. Pass `n * 2` to
    /// retrieve `n` complete turn pairs.
    func getRecentTurns(n: Int) throws -> [ConversationTurn] {
        try db.read { db in
            try ConversationTurn
                .order(Column("timestamp").desc)
                .limit(n)
                .fetchAll(db)
                .reversed()
        }
    }

    /// Returns all messages that belong to a specific session, ordered
    /// chronologically. Used by `MemorySummariser` to build the extraction prompt.
    func getSessionTurns(sessionID: String) throws -> [ConversationTurn] {
        try db.read { db in
            try ConversationTurn
                .filter(Column("session_id") == sessionID)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    // MARK: – SessionSummary

    /// Persists a summary produced by `MemorySummariser` at session end.
    func saveSessionSummary(_ text: String) throws {
        var summary = SessionSummary(
            id:          nil,
            summaryText: text,
            timestamp:   Date().timeIntervalSince1970
        )
        try db.write { db in try summary.insert(db) }
    }

    /// Returns the `n` most recent session summaries, ordered oldest-first
    /// (so they read chronologically when concatenated).
    func getRecentSummaries(n: Int) throws -> [SessionSummary] {
        try db.read { db in
            try SessionSummary
                .order(Column("timestamp").desc)
                .limit(n)
                .fetchAll(db)
                .reversed()
        }
    }

    // MARK: – Convenience

    /// Returns a formatted memory string ready to inject into the Groq system
    /// prompt as "What you remember about this user:". Returns `""` when the
    /// store is empty (first ever session).
    ///
    /// Summaries are separated by `---` so the model sees them as distinct
    /// snapshots in time rather than one continuous block.
    func buildMemorySummary(recentSessions: Int = 5) throws -> String {
        let summaries = try getRecentSummaries(n: recentSessions)
        guard !summaries.isEmpty else { return "" }
        return summaries
            .map(\.summaryText)
            .joined(separator: "\n\n---\n\n")
    }
}
