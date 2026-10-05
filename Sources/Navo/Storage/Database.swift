import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DictationStatus: String {
    case ok
    case failed
}

struct Dictation: Identifiable, Equatable, Hashable {
    let id: String
    var createdAt: Date
    var duration: Double
    var language: String
    var rawText: String
    var cleanText: String
    var appName: String?
    var appBundleID: String?
    var wordCount: Int
    var audioPath: String?
    var engine: String?
    var cleanup: String?
    var latencyMs: Int?
    var status: DictationStatus
    var errorMessage: String?

    var hasAudio: Bool {
        guard let audioPath else { return false }
        return FileManager.default.fileExists(atPath: audioPath)
    }
}

enum SessionKind: String {
    case meeting
    case file
}

enum SessionStatus: String {
    case recording
    case ready
    case transcribing
    case done
    case partial
    case failed
}

/// One transcribed part of a long recording.
struct SessionChunk: Codable, Equatable, Hashable {
    var index: Int
    var start: Double
    var end: Double
    var text: String?
    var error: String?
}

/// A recorded meeting or an imported audio file, and its transcript.
struct Session: Identifiable, Equatable, Hashable {
    let id: String
    var kind: SessionKind
    var title: String
    var createdAt: Date
    var duration: Double
    /// mic, system or both for a meeting; the original file name for an import.
    var source: String
    var audioPath: String?
    var status: SessionStatus
    var engine: String?
    var language: String
    var chunks: [SessionChunk]
    var error: String?

    var transcript: String {
        chunks.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var hasAudio: Bool {
        guard let audioPath else { return false }
        return FileManager.default.fileExists(atPath: audioPath)
    }

    var failedChunks: Int {
        chunks.filter { $0.text == nil }.count
    }
}

/// Text copied anywhere on the Mac, kept for the Clipboard tab.
struct ClipItem: Identifiable, Equatable, Hashable {
    let id: String
    /// The start of the text (the full text is read when it is copied again).
    var preview: String
    var characters: Int
    var copiedAt: Date
    var appName: String?
    var appBundleID: String?
    var starred: Bool
}

struct VocabularyItem: Identifiable, Equatable, Hashable {
    let id: String
    var term: String
    var replacement: String?
    var createdAt: Date
}

struct UsageStats: Equatable {
    var totalWords = 0
    var totalDictations = 0
    var totalSeconds = 0.0
    var streakDays = 0
    var wordsToday = 0

    var averageWPM: Int {
        totalSeconds > 5 ? Int((Double(totalWords) / (totalSeconds / 60)).rounded()) : 0
    }

    /// Minutes saved versus typing at 40 wpm.
    var minutesSaved: Int {
        max(0, Int((Double(totalWords) / 40.0 - totalSeconds / 60.0).rounded()))
    }
}

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { "Database error: \(message)" }
}

/// Thin SQLite wrapper. The connection is opened in serialized mode, so it is safe to use from any thread.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?

    private enum Value {
        case text(String?)
        case double(Double)
        case int(Int?)
    }

    private static let columns =
        "id, created_at, duration, language, raw_text, clean_text, app_name, app_bundle_id, word_count, audio_path, engine, cleanup, latency_ms, status, error"

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(handle)
            throw DatabaseError(message: message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try exec("PRAGMA journal_mode=WAL;")
        // Overwrite deleted content with zeros instead of leaving it in free pages.
        try exec("PRAGMA secure_delete=ON;")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Schema

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version;")
        if version < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS dictations (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                language TEXT NOT NULL DEFAULT '',
                raw_text TEXT NOT NULL DEFAULT '',
                clean_text TEXT NOT NULL DEFAULT '',
                app_name TEXT,
                app_bundle_id TEXT,
                word_count INTEGER NOT NULL DEFAULT 0,
                audio_path TEXT,
                engine TEXT,
                cleanup TEXT,
                latency_ms INTEGER,
                status TEXT NOT NULL DEFAULT 'ok',
                error TEXT,
                search_text TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_dictations_created ON dictations(created_at DESC);
            CREATE TABLE IF NOT EXISTS vocabulary (
                id TEXT PRIMARY KEY,
                term TEXT NOT NULL,
                replacement TEXT,
                created_at REAL NOT NULL
            );
            PRAGMA user_version = 1;
            """)
        }
        if version < 2 {
            try exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                source TEXT NOT NULL DEFAULT '',
                audio_path TEXT,
                status TEXT NOT NULL,
                engine TEXT,
                language TEXT NOT NULL DEFAULT 'ar',
                transcript TEXT NOT NULL DEFAULT '',
                chunks TEXT NOT NULL DEFAULT '[]',
                error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_created ON sessions(created_at DESC);
            PRAGMA user_version = 2;
            """)
        }
        if version < 3 {
            try exec("""
            CREATE TABLE IF NOT EXISTS clipboard (
                id TEXT PRIMARY KEY,
                text TEXT NOT NULL,
                hash TEXT NOT NULL UNIQUE,
                copied_at REAL NOT NULL,
                app_name TEXT,
                app_bundle_id TEXT,
                starred INTEGER NOT NULL DEFAULT 0,
                characters INTEGER NOT NULL DEFAULT 0,
                search_text TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_clipboard_copied ON clipboard(copied_at DESC);
            PRAGMA user_version = 3;
            """)
        }
    }

    // MARK: Dictations

    func save(_ item: Dictation) throws {
        let values: [Value] = [
            .text(item.id),
            .double(item.createdAt.timeIntervalSince1970),
            .double(item.duration),
            .text(item.language),
            .text(item.rawText),
            .text(item.cleanText),
            .text(item.appName),
            .text(item.appBundleID),
            .int(item.wordCount),
            .text(item.audioPath),
            .text(item.engine),
            .text(item.cleanup),
            .int(item.latencyMs),
            .text(item.status.rawValue),
            .text(item.errorMessage),
            .text(TextTools.searchKey([item.cleanText, item.rawText, item.appName ?? ""].joined(separator: "\n"))),
        ]
        try run(
            "INSERT OR REPLACE INTO dictations (\(Self.columns), search_text) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            values
        )
    }

    func deleteDictation(id: String) throws {
        try run("DELETE FROM dictations WHERE id = ?", [.text(id)])
    }

    func deleteAllDictations() throws {
        try run("DELETE FROM dictations")
    }

    // MARK: Date-range cleanup

    /// Rows with created_at < before (when set) and created_at >= since (when set).
    private func rangeClause(before: Date?, since: Date?) -> (String, [Value]) {
        var parts: [String] = []
        var values: [Value] = []
        if let before {
            parts.append("created_at < ?")
            values.append(.double(before.timeIntervalSince1970))
        }
        if let since {
            parts.append("created_at >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        return (parts.isEmpty ? "1" : parts.joined(separator: " AND "), values)
    }

    func countDictations(before: Date?, since: Date?, withAudioOnly: Bool = false) throws -> Int {
        let (clause, values) = rangeClause(before: before, since: since)
        let audio = withAudioOnly ? " AND audio_path IS NOT NULL" : ""
        return try query("SELECT COUNT(*) FROM dictations WHERE \(clause)\(audio)", values) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    func audioPaths(before: Date?, since: Date?) throws -> [String] {
        let (clause, values) = rangeClause(before: before, since: since)
        return try query("SELECT audio_path FROM dictations WHERE \(clause) AND audio_path IS NOT NULL", values) {
            Self.text($0, 0) ?? ""
        }.filter { !$0.isEmpty }
    }

    @discardableResult
    func deleteDictations(before: Date?, since: Date?) throws -> Int {
        let (clause, values) = rangeClause(before: before, since: since)
        try run("DELETE FROM dictations WHERE \(clause)", values)
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    func clearAudioPaths(before: Date?, since: Date?) throws -> Int {
        let (clause, values) = rangeClause(before: before, since: since)
        try run("UPDATE dictations SET audio_path = NULL WHERE \(clause) AND audio_path IS NOT NULL", values)
        return Int(sqlite3_changes(db))
    }

    /// Makes deletions final: flushes the write-ahead log into the file and rebuilds it without free pages.
    func compact() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try exec("VACUUM;")
    }

    /// Latest dictations; every whitespace-separated term of `search` must match.
    func dictations(search: String, limit: Int) throws -> [Dictation] {
        let terms = TextTools.searchKey(search)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var sql = "SELECT \(Self.columns) FROM dictations"
        var values: [Value] = []
        if !terms.isEmpty {
            sql += " WHERE " + terms.map { _ in "search_text LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            values = terms.map { .text("%" + Self.escapeLike($0) + "%") }
        }
        sql += " ORDER BY created_at DESC LIMIT ?"
        values.append(.int(limit))
        return try query(sql, values, map: Self.dictation)
    }

    func stats(now: Date = Date()) throws -> UsageStats {
        var stats = UsageStats()
        _ = try query("SELECT COALESCE(SUM(word_count), 0), COUNT(*), COALESCE(SUM(duration), 0) FROM dictations WHERE status = 'ok'") { stmt in
            stats.totalWords = Int(sqlite3_column_int64(stmt, 0))
            stats.totalDictations = Int(sqlite3_column_int64(stmt, 1))
            stats.totalSeconds = sqlite3_column_double(stmt, 2)
        }

        let startOfToday = Calendar.current.startOfDay(for: now)
        stats.wordsToday = try query(
            "SELECT COALESCE(SUM(word_count), 0) FROM dictations WHERE status = 'ok' AND created_at >= ?",
            [.double(startOfToday.timeIntervalSince1970)]
        ) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0

        let days = try query(
            "SELECT DISTINCT date(created_at, 'unixepoch', 'localtime') AS day FROM dictations WHERE status = 'ok' ORDER BY day DESC LIMIT 400"
        ) { Self.text($0, 0) ?? "" }
        stats.streakDays = Self.streak(days: days, now: now)
        return stats
    }

    private static func streak(days: [String], now: Date) -> Int {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let dates = Set(days.compactMap { formatter.date(from: $0).map { calendar.startOfDay(for: $0) } })
        var cursor = calendar.startOfDay(for: now)
        if !dates.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor), dates.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while dates.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    // MARK: Vocabulary

    func vocabulary() throws -> [VocabularyItem] {
        try query("SELECT id, term, replacement, created_at FROM vocabulary ORDER BY term COLLATE NOCASE") { stmt in
            VocabularyItem(
                id: Self.text(stmt, 0) ?? UUID().uuidString,
                term: Self.text(stmt, 1) ?? "",
                replacement: Self.text(stmt, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            )
        }
    }

    func saveVocabulary(_ item: VocabularyItem) throws {
        try run(
            "INSERT OR REPLACE INTO vocabulary (id, term, replacement, created_at) VALUES (?,?,?,?)",
            [.text(item.id), .text(item.term), .text(item.replacement), .double(item.createdAt.timeIntervalSince1970)]
        )
    }

    func deleteVocabulary(id: String) throws {
        try run("DELETE FROM vocabulary WHERE id = ?", [.text(id)])
    }

    // MARK: Sessions (meetings and imported files)

    private static let sessionColumns =
        "id, kind, title, created_at, duration, source, audio_path, status, engine, language, chunks, error"

    func saveSession(_ item: Session) throws {
        let chunks = (try? JSONEncoder().encode(item.chunks)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try run(
            "INSERT OR REPLACE INTO sessions (\(Self.sessionColumns), transcript) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [
                .text(item.id),
                .text(item.kind.rawValue),
                .text(item.title),
                .double(item.createdAt.timeIntervalSince1970),
                .double(item.duration),
                .text(item.source),
                .text(item.audioPath),
                .text(item.status.rawValue),
                .text(item.engine),
                .text(item.language),
                .text(chunks),
                .text(item.error),
                .text(item.transcript),
            ]
        )
    }

    func sessions() throws -> [Session] {
        try query("SELECT \(Self.sessionColumns) FROM sessions ORDER BY created_at DESC") { stmt in
            let chunksJSON = Self.text(stmt, 10) ?? "[]"
            let chunks = (try? JSONDecoder().decode([SessionChunk].self, from: Data(chunksJSON.utf8))) ?? []
            return Session(
                id: Self.text(stmt, 0) ?? UUID().uuidString,
                kind: SessionKind(rawValue: Self.text(stmt, 1) ?? "") ?? .file,
                title: Self.text(stmt, 2) ?? "",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                duration: sqlite3_column_double(stmt, 4),
                source: Self.text(stmt, 5) ?? "",
                audioPath: Self.text(stmt, 6),
                status: SessionStatus(rawValue: Self.text(stmt, 7) ?? "") ?? .ready,
                engine: Self.text(stmt, 8),
                language: Self.text(stmt, 9) ?? "ar",
                chunks: chunks,
                error: Self.text(stmt, 11)
            )
        }
    }

    func deleteSession(id: String) throws {
        try run("DELETE FROM sessions WHERE id = ?", [.text(id)])
    }

    // MARK: Clipboard history

    /// Adds a copy, or moves the same text copied again to the top (keeping its star).
    func saveClip(id: String, text: String, hash: String, copiedAt: Date, appName: String?, appBundleID: String?, searchText: String) throws {
        try run(
            """
            INSERT INTO clipboard (id, text, hash, copied_at, app_name, app_bundle_id, characters, search_text)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(hash) DO UPDATE SET
                copied_at = excluded.copied_at,
                app_name = excluded.app_name,
                app_bundle_id = excluded.app_bundle_id
            """,
            [
                .text(id),
                .text(text),
                .text(hash),
                .double(copiedAt.timeIntervalSince1970),
                .text(appName),
                .text(appBundleID),
                .int(text.count),
                .text(searchText),
            ]
        )
    }

    /// Newest first; every whitespace-separated term of `search` must match.
    func clips(search: String, starredOnly: Bool, limit: Int, previewLength: Int) throws -> [ClipItem] {
        let terms = TextTools.searchKey(search)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var conditions: [String] = []
        var values: [Value] = [.int(previewLength)]
        if starredOnly {
            conditions.append("starred = 1")
        }
        for term in terms {
            conditions.append("search_text LIKE ? ESCAPE '\\'")
            values.append(.text("%" + Self.escapeLike(term) + "%"))
        }
        var sql = "SELECT id, substr(text, 1, ?), characters, copied_at, app_name, app_bundle_id, starred FROM clipboard"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY copied_at DESC LIMIT ?"
        values.append(.int(limit))
        return try query(sql, values) { stmt in
            ClipItem(
                id: Self.text(stmt, 0) ?? "",
                preview: Self.text(stmt, 1) ?? "",
                characters: Int(sqlite3_column_int64(stmt, 2)),
                copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                appName: Self.text(stmt, 4),
                appBundleID: Self.text(stmt, 5),
                starred: sqlite3_column_int64(stmt, 6) != 0
            )
        }
    }

    func clipText(id: String) throws -> String? {
        try query("SELECT text FROM clipboard WHERE id = ?", [.text(id)]) { Self.text($0, 0) }.first ?? nil
    }

    func clipCount() throws -> (all: Int, starred: Int) {
        let all = try scalarInt("SELECT COUNT(*) FROM clipboard;")
        let starred = try scalarInt("SELECT COUNT(*) FROM clipboard WHERE starred = 1;")
        return (all, starred)
    }

    /// Makes an item the newest, as if it had just been copied.
    func touchClip(id: String, at date: Date) throws {
        try run("UPDATE clipboard SET copied_at = ? WHERE id = ?", [.double(date.timeIntervalSince1970), .text(id)])
    }

    func setClipStarred(id: String, starred: Bool) throws {
        try run("UPDATE clipboard SET starred = ? WHERE id = ?", [.int(starred ? 1 : 0), .text(id)])
    }

    func deleteClip(id: String) throws {
        try run("DELETE FROM clipboard WHERE id = ?", [.text(id)])
        try checkpoint()
    }

    /// Removes every item that is not starred. Returns how many were removed.
    @discardableResult
    func deleteUnstarredClips() throws -> Int {
        try run("DELETE FROM clipboard WHERE starred = 0")
        let removed = Int(sqlite3_changes(db))
        try checkpoint()
        return removed
    }

    /// Removes items that are not starred and are older than `before`, beyond the newest
    /// `keep`, or beyond `maxCharacters` of text counted from the newest.
    @discardableResult
    func pruneClips(before: Date, keep: Int, maxCharacters: Int) throws -> Int {
        try run(
            """
            DELETE FROM clipboard WHERE id IN (
                SELECT id FROM (
                    SELECT id, copied_at,
                        ROW_NUMBER() OVER (ORDER BY copied_at DESC) AS position,
                        SUM(characters) OVER (ORDER BY copied_at DESC ROWS UNBOUNDED PRECEDING) AS running
                    FROM clipboard WHERE starred = 0
                ) WHERE copied_at < ? OR position > ? OR running > ?
            )
            """,
            [.double(before.timeIntervalSince1970), .int(keep), .int(maxCharacters)]
        )
        let removed = Int(sqlite3_changes(db))
        if removed > 0 {
            try checkpoint()
        }
        return removed
    }

    /// Moves the write-ahead log into the database file, where deleted text is already zeroed
    /// (secure_delete), so nothing deleted stays behind in the log.
    func checkpoint() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: Plumbing

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError(message: lastError)
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ values: [Value]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string):
                if let string {
                    sqlite3_bind_text(stmt, index, string, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, index)
                }
            case .double(let number):
                sqlite3_bind_double(stmt, index, number)
            case .int(let number):
                if let number {
                    sqlite3_bind_int64(stmt, index, Int64(number))
                } else {
                    sqlite3_bind_null(stmt, index)
                }
            }
        }
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw DatabaseError(message: lastError)
        }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], map: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        var rows: [T] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_ROW {
                rows.append(map(stmt))
            } else if code == SQLITE_DONE {
                break
            } else {
                throw DatabaseError(message: lastError)
            }
        }
        return rows
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try query(sql) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: pointer)
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func dictation(_ stmt: OpaquePointer) -> Dictation {
        let latency: Int? = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 12))
        return Dictation(
            id: text(stmt, 0) ?? UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            duration: sqlite3_column_double(stmt, 2),
            language: text(stmt, 3) ?? "",
            rawText: text(stmt, 4) ?? "",
            cleanText: text(stmt, 5) ?? "",
            appName: text(stmt, 6),
            appBundleID: text(stmt, 7),
            wordCount: Int(sqlite3_column_int64(stmt, 8)),
            audioPath: text(stmt, 9),
            engine: text(stmt, 10),
            cleanup: text(stmt, 11),
            latencyMs: latency,
            status: DictationStatus(rawValue: text(stmt, 13) ?? "ok") ?? .ok,
            errorMessage: text(stmt, 14)
        )
    }
}
