import Foundation
import GRDB
import HaloDomain
import HaloFoundation
import Synchronization

/// `LocalSearchIndexPort` over `search-index.sqlite` (DATA_MODELS §3b, D123, D124): one file per account in the app's private folder, with
/// `complete` protection and no backup. It is derived data: a damaged file or one of another version is deleted and filled again.
/// While the phone is locked the file can't be opened; writes then go, encrypted, to the holding file and move over at the next opening.
public final class SearchIndexStore: LocalSearchIndexPort {
    /// Any other version is deleted (MIGRATIONS §1b).
    static let schemaVersion = 1

    private struct State {
        var pool: DatabasePool?
        /// The phone is locked (or the app said so).
        var suspended = false
    }

    private let directory: URL
    private let holding: SearchHoldingFile?
    private let isReadable: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    /// - Parameters:
    ///   - directory: the account's own folder; created when needed.
    ///   - cipher: encrypts the holding file; without one, nothing is kept while the index can't be opened.
    ///   - isReadable: whether protected files can be opened now.
    public init(directory: URL, cipher: FieldCipher?, isReadable: @escaping @Sendable () -> Bool = { true }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.isReadable = isReadable
        self.now = now
        holding = cipher.map { SearchHoldingFile(directory: directory, cipher: $0) }
    }

    private var path: String { directory.appendingPathComponent("search-index.sqlite").path }

    // MARK: Opening and locking

    /// The phone is about to lock: nothing may touch the file until `resume`. Keeps what is to be read next for a processing task.
    public func suspend(rooms: [RoomID]) async {
        if let holding, let work = try? await nextWork(rooms: rooms, limit: SearchHoldingFile.plannedWork) { holding.save(plan: work) }
        let pool = state.withLock { state in
            state.suspended = true
            defer { state.pool = nil }
            return state.pool
        }
        pool?.interrupt()
        try? pool?.close()
    }

    /// The phone was unlocked: opens the file and applies what was held meanwhile.
    public func resume() async {
        state.withLock { $0.suspended = false }
        _ = try? await database()
    }

    /// Deletes the index and the holding file of every account (sign-out, revocation; AC-SRCH-8).
    public static func removeAll(in parent: URL) { try? FileManager.default.removeItem(at: parent) }

    /// Closes the file and deletes this account's folder.
    public func destroy() {
        let pool = state.withLock { state in
            state.suspended = true
            defer { state.pool = nil }
            return state.pool
        }
        pool?.interrupt()
        try? pool?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func database() async throws(HaloError) -> DatabasePool {
        let opened: (pool: DatabasePool, isNew: Bool) = try state.withLock { state throws(HaloError) in
            if let pool = state.pool { return (pool, false) }
            guard !state.suspended, isReadable() else { throw .storage(.unavailable) }
            let pool = try open()
            state.pool = pool
            return (pool, true)
        }
        if opened.isNew, let holding {
            for operations in holding.take() { try await write(operations, to: opened.pool) }
            holding.clear()
        }
        return opened.pool
    }

    private func open() throws(HaloError) -> DatabasePool {
        do {
            try prepareDirectory()
            do { return try openFile() } catch where Self.isDamaged(error) {
                // Derived data: never migrated, never repaired.
                removeFiles()
                return try openFile()
            }
        } catch let error as HaloError { throw error } catch { throw .storage(.unavailable) }
    }

    /// Only what the file itself says: one that iOS doesn't let us open now (locked phone, no space) is kept.
    private static func isDamaged(_ error: any Error) -> Bool {
        if error is OtherVersion { return true }
        guard let error = error as? DatabaseError else { return false }
        return [.SQLITE_CORRUPT, .SQLITE_NOTADB].contains(error.resultCode.primaryResultCode)
    }

    private struct OtherVersion: Error {}

    private func openFile() throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "search-index"
        configuration.qos = .utility
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // Deleted messages leave no text behind in free pages.
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        let pool = try DatabasePool(path: path, configuration: configuration)
        let version = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        if version == 0 {
            try pool.write { try Self.createSchema($0) }
        } else if version != Self.schemaVersion {
            try pool.close()
            throw OtherVersion()
        }
        protectFiles()
        return pool
    }

    private static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE room (id INTEGER PRIMARY KEY, room_id TEXT NOT NULL UNIQUE);
            CREATE TABLE sender (id INTEGER PRIMARY KEY, user_id TEXT NOT NULL UNIQUE, name TEXT);
            CREATE TABLE event (
              id INTEGER PRIMARY KEY, room INTEGER NOT NULL, sender INTEGER NOT NULL, event_id TEXT NOT NULL, thread_root TEXT,
              ts INTEGER NOT NULL, kind INTEGER NOT NULL, body TEXT NOT NULL, searchable TEXT NOT NULL, checked_at INTEGER NOT NULL,
              UNIQUE (room, event_id));
            CREATE INDEX event_room ON event(room, ts DESC);
            CREATE INDEX event_kind ON event(kind, ts DESC);
            CREATE INDEX event_time ON event(ts DESC);
            CREATE TABLE coverage (room INTEGER PRIMARY KEY, state INTEGER NOT NULL, anchor TEXT, oldest INTEGER, updated_at INTEGER NOT NULL);
            -- newer_event_id '' asks for a comparison with the server first.
            CREATE TABLE gap (room INTEGER NOT NULL, newer_event_id TEXT NOT NULL, PRIMARY KEY (room, newer_event_id));
            -- Events known by ID only: 0 no key yet, 1 nothing to search in them.
            CREATE TABLE pending (
              room INTEGER NOT NULL, event_id TEXT NOT NULL, state INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (room, event_id));
            CREATE INDEX pending_due ON pending(state, next_at);
            """)
        // The tokeniser of HaloDomain has already folded the text; marks stay part of their word. Own triggers instead of GRDB's: taking a
        // row out of the full-text index costs 3 ms (secure-delete), so it only happens when the words change.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE event_fts USING fts5(
              searchable, content='event', content_rowid='id', prefix='2 3', tokenize="unicode61 remove_diacritics 0 categories 'L* N* M* Co'");
            INSERT INTO event_fts(event_fts, rank) VALUES ('secure-delete', 1);
            CREATE TRIGGER event_added AFTER INSERT ON event BEGIN
              INSERT INTO event_fts(rowid, searchable) VALUES (new.id, new.searchable);
            END;
            CREATE TRIGGER event_removed AFTER DELETE ON event BEGIN
              INSERT INTO event_fts(event_fts, rowid, searchable) VALUES ('delete', old.id, old.searchable);
            END;
            CREATE TRIGGER event_changed AFTER UPDATE OF searchable ON event WHEN old.searchable <> new.searchable BEGIN
              INSERT INTO event_fts(event_fts, rowid, searchable) VALUES ('delete', old.id, old.searchable);
              INSERT INTO event_fts(rowid, searchable) VALUES (new.id, new.searchable);
            END;
            """)
        try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// `complete`: unreadable while the phone is locked (D124).
    private func protectFiles() {
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path + suffix)
        }
    }

    private func removeFiles() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// Deletes the file after SQLite said it is damaged; the next call starts an empty one.
    private func discard() {
        let pool = state.withLock { state in
            defer { state.pool = nil }
            return state.pool
        }
        try? pool?.close()
        removeFiles()
    }

    private func map(_ error: any Error) -> HaloError {
        switch error {
        case let error as HaloError: return error
        case is CancellationError: return .cancelled
        case let error as DatabaseError:
            switch error.resultCode.primaryResultCode {
            case .SQLITE_CORRUPT, .SQLITE_NOTADB:
                discard()
                return .storage(.corrupted)
            case .SQLITE_INTERRUPT, .SQLITE_ABORT: return .cancelled
            case .SQLITE_FULL: return .storage(.unavailable)
            default: return .storage(.unavailable)
            }
        default: return .storage(.unavailable)
        }
    }

    // MARK: Writing

    public func apply(_ operations: [SearchIndexOperation]) async throws(HaloError) {
        let pool: DatabasePool
        do { pool = try await database() } catch {
            guard error == .storage(.unavailable), let holding else { throw error }
            try holding.append(operations)
            return
        }
        try await write(operations, to: pool)
    }

    private func write(_ operations: [SearchIndexOperation], to pool: DatabasePool) async throws(HaloError) {
        let stamp = Self.milliseconds(now())
        do {
            var rest = operations[...]
            while let first = rest.first {
                if case .removeRooms(let rooms) = first {
                    rest = rest.dropFirst()
                    for room in rooms { try await remove(room, from: pool) }
                    continue
                }
                let part = rest.prefix { if case .removeRooms = $0 { false } else { true } }
                rest = rest.dropFirst(part.count)
                try await pool.write { db in
                    for operation in part { try Self.apply(operation, stamp: stamp, db) }
                }
            }
        } catch { throw map(error) }
    }

    /// In small steps, so other writes aren't held up: a large room takes a while. Interrupted, it is taken up again at the next start.
    private func remove(_ room: RoomID, from pool: DatabasePool) async throws {
        while true {
            let left = try await pool.write { db -> Bool in
                guard let id = try Self.roomRow(room, create: false, db) else { return false }
                try db.execute(sql: "DELETE FROM event WHERE id IN (SELECT id FROM event WHERE room = ? LIMIT 100)", arguments: [id])
                if db.changesCount > 0 { return true }
                for table in ["coverage", "gap", "pending"] { try db.execute(sql: "DELETE FROM \(table) WHERE room = ?", arguments: [id]) }
                try db.execute(sql: "DELETE FROM room WHERE id = ?", arguments: [id])
                return false
            }
            if !left { return }
        }
    }

    private static func apply(_ operation: SearchIndexOperation, stamp: Int64, _ db: Database) throws {
        switch operation {
        case .live(let events):
            for event in events { try apply(event, stamp: stamp, db) }
        case .slice(let slice, let target):
            try apply(slice, target: target, stamp: stamp, db)
        case .check(let rooms):
            for room in rooms {
                // Never read: starts at its newest event anyway.
                guard let id = try roomRow(room, create: false, db), try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM coverage WHERE room = ?)", arguments: [id]) ?? false else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO gap (room, newer_event_id) VALUES (?, '')", arguments: [id])
            }
        case .checked(let room, let gapFrom):
            guard let id = try roomRow(room, create: false, db) else { return }
            try db.execute(sql: "DELETE FROM gap WHERE room = ? AND newer_event_id = ''", arguments: [id])
            if let gapFrom { try db.execute(sql: "INSERT OR IGNORE INTO gap (room, newer_event_id) VALUES (?, ?)", arguments: [id, gapFrom.rawValue]) }
        case .blocked(let room):
            let id = try roomRow(room, db)
            try db.execute(sql: "DELETE FROM gap WHERE room = ?", arguments: [id])
            try db.execute(
                sql: "INSERT INTO coverage (room, state, updated_at) VALUES (?, ?, ?) ON CONFLICT (room) DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at",
                arguments: [id, RoomSearchState.blocked.rawValue, stamp])
        case .removeRooms: break  // `remove`
        }
    }

    private static func apply(_ event: SearchLiveEvent, stamp: Int64, _ db: Database) throws {
        switch event {
        case .message(let entry): try upsert(entry, stamp: stamp, db)
        case .edit(let room, let target, let sender, let content):
            guard let id = try roomRow(room, create: false, db) else { return }
            try db.execute(
                sql: """
                    UPDATE event SET body = ?, kind = ?, checked_at = ?, searchable = ? || ' ' || coalesce((SELECT name FROM sender WHERE id = event.sender), '')
                    WHERE room = ? AND event_id = ? AND sender = (SELECT id FROM sender WHERE user_id = ?)
                    """,
                arguments: [content.body, content.kind.rawValue, stamp, SearchTokeniser.indexText([content.body] + content.extra), id, target.rawValue, sender.rawValue])
        case .undecryptable(let room, let event): try pend(event, room: try roomRow(room, db), stamp: stamp, db)
        case .removed(let room, let event):
            guard let id = try roomRow(room, create: false, db) else { return }
            try db.execute(sql: "DELETE FROM event WHERE room = ? AND event_id = ?", arguments: [id, event.rawValue])
            try db.execute(sql: "DELETE FROM pending WHERE room = ? AND event_id = ?", arguments: [id, event.rawValue])
        }
    }

    private static func apply(_ slice: SearchHistorySlice, target: SearchIndexOperation.SliceTarget, stamp: Int64, _ db: Database) throws {
        let room = try roomRow(target.room, db)
        let anchor = try String.fetchOne(db, sql: "SELECT anchor FROM coverage WHERE room = ?", arguments: [room])
        // Before anything of the slice is written: whether it reaches messages the index knew.
        var meetsKnown = false
        if case .gap = target, let oldest = slice.entries.first?.event ?? slice.undecryptable.first {
            meetsKnown = try isKnown(oldest, room: room, db) || (anchor.map { known in (slice.entries.map(\.event) + slice.undecryptable + slice.other).contains { $0.rawValue == known } } ?? false)
        }
        for entry in slice.entries { try upsert(entry, stamp: stamp, db) }
        for event in slice.undecryptable { try pend(event, room: room, stamp: stamp, db) }
        for event in slice.other {
            try db.execute(sql: "DELETE FROM event WHERE room = ? AND event_id = ?", arguments: [room, event.rawValue])
            try db.execute(sql: "DELETE FROM pending WHERE room = ? AND event_id = ? AND state = 0", arguments: [room, event.rawValue])
        }
        switch target {
        case .history:
            let stuck = !slice.reachedStart && (slice.oldest == nil || slice.oldest?.rawValue == anchor)
            let state: RoomSearchState = slice.reachedStart ? .complete : (stuck ? .blocked : .partial)
            try db.execute(
                sql: """
                    INSERT INTO coverage (room, state, anchor, oldest, updated_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (room) DO UPDATE SET state = excluded.state, anchor = coalesce(excluded.anchor, anchor), oldest = coalesce(excluded.oldest, oldest), updated_at = excluded.updated_at
                    """,
                arguments: [room, state.rawValue, slice.oldest?.rawValue, slice.oldestTime.map(milliseconds), stamp])
        case .gap(_, let before):
            try db.execute(sql: "DELETE FROM gap WHERE room = ? AND newer_event_id = ?", arguments: [room, before.rawValue])
            for event in slice.other {
                try db.execute(sql: "INSERT OR IGNORE INTO pending (room, event_id, state) VALUES (?, ?, 1)", arguments: [room, event.rawValue])
            }
            if !meetsKnown, !slice.reachedStart, let oldest = slice.oldest, oldest != before {
                try db.execute(sql: "INSERT OR IGNORE INTO gap (room, newer_event_id) VALUES (?, ?)", arguments: [room, oldest.rawValue])
            }
        case .retry(_, let around):
            // Asked for and not in the answer: it is gone or not readable any more; later attempts come less often.
            if !slice.undecryptable.contains(around), !slice.entries.contains(where: { $0.event == around }) { try pend(around, room: room, stamp: stamp, db, onlyKnown: true) }
        }
    }

    private static func upsert(_ entry: SearchIndexEntry, stamp: Int64, _ db: Database) throws {
        let room = try roomRow(entry.room, db)
        let sender = try senderRow(entry.sender, name: entry.senderName, db)
        // A wrong clock must not put a message on top forever.
        let timestamp = min(milliseconds(entry.timestamp), stamp)
        try db.cachedStatement(sql: """
            INSERT INTO event (room, sender, event_id, thread_root, ts, kind, body, searchable, checked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (room, event_id) DO UPDATE SET
              thread_root = excluded.thread_root, ts = excluded.ts, kind = excluded.kind, body = excluded.body, searchable = excluded.searchable, checked_at = excluded.checked_at
            """).execute(arguments: [
                room, sender, entry.event.rawValue, entry.threadRoot?.rawValue, timestamp, entry.content.kind.rawValue, entry.content.body, entry.indexText, stamp,
            ])
        try db.cachedStatement(sql: "DELETE FROM pending WHERE room = ? AND event_id = ?").execute(arguments: [room, entry.event.rawValue])
    }

    /// Remembers a message without a key; seen again without one, the next attempt comes later.
    private static func pend(_ event: EventID, room: Int64, stamp: Int64, _ db: Database, onlyKnown: Bool = false) throws {
        let attempts = try Int.fetchOne(db, sql: "SELECT attempts FROM pending WHERE room = ? AND event_id = ? AND state = 0", arguments: [room, event.rawValue])
        if attempts == nil, onlyKnown { return }
        let next = (attempts ?? 0) + 1
        try db.execute(
            sql: """
                INSERT INTO pending (room, event_id, state, attempts, next_at) VALUES (?, ?, 0, ?, ?)
                ON CONFLICT (room, event_id) DO UPDATE SET state = 0, attempts = excluded.attempts, next_at = excluded.next_at
                """,
            arguments: [room, event.rawValue, next, stamp + Int64(SearchIndexPolicy.retryDelay(attempts: next) * 1000)])
    }

    private static func isKnown(_ event: EventID, room: Int64, _ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM event WHERE room = ?1 AND event_id = ?2) OR EXISTS (SELECT 1 FROM pending WHERE room = ?1 AND event_id = ?2)",
            arguments: [room, event.rawValue]) ?? false
    }

    private static func roomRow(_ room: RoomID, _ db: Database) throws -> Int64 {
        if let id = try roomRow(room, create: false, db) { return id }
        try db.execute(sql: "INSERT INTO room (room_id) VALUES (?)", arguments: [room.rawValue])
        return db.lastInsertedRowID
    }

    private static func roomRow(_ room: RoomID, create: Bool, _ db: Database) throws -> Int64? {
        try Int64.fetchOne(db.cachedStatement(sql: "SELECT id FROM room WHERE room_id = ?"), arguments: [room.rawValue])
    }

    private static func senderRow(_ user: UserID, name: String?, _ db: Database) throws -> Int64 {
        if let row = try Row.fetchOne(db.cachedStatement(sql: "SELECT id, name FROM sender WHERE user_id = ?"), arguments: [user.rawValue]) {
            let id: Int64 = row["id"]
            let known: String? = row["name"]
            if let name, name != known { try db.execute(sql: "UPDATE sender SET name = ? WHERE id = ?", arguments: [name, id]) }
            return id
        }
        try db.execute(sql: "INSERT INTO sender (user_id, name) VALUES (?, ?)", arguments: [user.rawValue, name])
        return db.lastInsertedRowID
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    public func record(_ rechecks: [(room: RoomID, event: EventID, result: SearchRecheck)]) async throws(HaloError) {
        let pool = try await database()
        let stamp = Self.milliseconds(now())
        do {
            try await pool.write { db in
                for recheck in rechecks {
                    guard let room = try Self.roomRow(recheck.room, create: false, db) else { continue }
                    switch recheck.result {
                    case .unchecked: continue
                    case .unchanged:
                        try db.execute(sql: "UPDATE event SET checked_at = ? WHERE room = ? AND event_id = ?", arguments: [stamp, room, recheck.event.rawValue])
                    case .edited(let content):
                        try db.execute(
                            sql: """
                                UPDATE event SET body = ?, kind = ?, checked_at = ?, searchable = ? || ' ' || coalesce((SELECT name FROM sender WHERE id = event.sender), '')
                                WHERE room = ? AND event_id = ?
                                """,
                            arguments: [content.body, content.kind.rawValue, stamp, SearchTokeniser.indexText([content.body] + content.extra), room, recheck.event.rawValue])
                    case .gone:
                        try db.execute(sql: "DELETE FROM event WHERE room = ? AND event_id = ?", arguments: [room, recheck.event.rawValue])
                    }
                }
            }
        } catch { throw map(error) }
    }

    public func retryUndecryptableNow() async throws(HaloError) {
        let pool = try await database()
        do { try await pool.write { try $0.execute(sql: "UPDATE pending SET next_at = 0, attempts = 0 WHERE state = 0") } } catch { throw map(error) }
    }

    public func clear() async throws(HaloError) {
        _ = try await database()
        // Faster than deleting rows one by one, and nothing of them stays.
        discard()
        _ = try await database()
    }

    // MARK: Reading

    public func hits(match: String, room: RoomID?, kinds: Set<SearchKind>, excluding: Set<UserID>, after cursor: SearchCursor?, limit: Int) async throws(HaloError) -> [SearchIndexHit] {
        let pool = try await database()
        var sql = """
            SELECT e.id, r.room_id, s.user_id, s.name, e.event_id, e.thread_root, e.ts, e.kind, e.body, e.checked_at
            FROM event_fts f JOIN event e ON e.id = f.rowid JOIN room r ON r.id = e.room JOIN sender s ON s.id = e.sender
            WHERE event_fts MATCH ?
            """
        var arguments: [(any DatabaseValueConvertible)?] = [match]
        if let room {
            sql += " AND r.room_id = ?"
            arguments.append(room.rawValue)
        }
        if kinds.count < SearchKind.allCases.count {
            sql += " AND e.kind IN (\(kinds.map { String($0.rawValue) }.sorted().joined(separator: ",")))"
        }
        if !excluding.isEmpty {
            sql += " AND s.user_id NOT IN (\(databaseQuestionMarks(count: excluding.count)))"
            for user in excluding { arguments.append(user.rawValue) }
        }
        if let cursor {
            sql += " AND (e.ts, e.id) < (?, ?)"
            arguments.append(cursor.timestamp)
            arguments.append(cursor.row)
        }
        sql += " ORDER BY e.ts DESC, e.id DESC LIMIT ?"
        arguments.append(limit)
        let statement = sql, values = StatementArguments(arguments)
        do {
            return try await pool.read { db in
                try Row.fetchAll(db, sql: statement, arguments: values).compactMap { row -> SearchIndexHit? in
                    guard let room = try? RoomID(row["room_id"]), let event = try? EventID(row["event_id"]), let sender = try? UserID(row["user_id"]) else { return nil }
                    let thread: String? = row["thread_root"]
                    return SearchIndexHit(
                        entry: SearchIndexEntry(
                            room: room, event: event, sender: sender, senderName: row["name"], threadRoot: thread.flatMap { try? EventID($0) }, timestamp: Self.date(row["ts"]),
                            content: SearchableContent(kind: SearchKind(rawValue: row["kind"]) ?? .message, body: row["body"])),
                        cursor: SearchCursor(timestamp: row["ts"], row: row["id"]), checkedAt: Self.date(row["checked_at"]))
                }
            }
        } catch { throw map(error) }
    }

    public func nextWork(rooms: [RoomID], limit: Int) async throws(HaloError) -> [SearchHistoryWork] {
        let pool: DatabasePool
        do { pool = try await database() } catch {
            guard error == .storage(.unavailable), let holding else { throw error }
            return Array(holding.plan().prefix(limit))
        }
        let stamp = Self.milliseconds(now())
        do {
            return try await pool.read { db in
                let joined = Set(rooms)
                func works(_ sql: String, _ arguments: StatementArguments = [], _ make: (RoomID, EventID?) -> SearchHistoryWork?) throws -> [SearchHistoryWork] {
                    try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                        guard let room = try? RoomID(row["room_id"]), joined.contains(room) else { return nil }
                        let event: String? = row["event_id"]
                        return make(room, event.flatMap { try? EventID($0) })
                    }
                }
                var result = try works("SELECT r.room_id, NULL AS event_id FROM gap g JOIN room r ON r.id = g.room WHERE g.newer_event_id = '' LIMIT 100") { room, _ in .check(room) }
                result += try works("SELECT r.room_id, g.newer_event_id AS event_id FROM gap g JOIN room r ON r.id = g.room WHERE g.newer_event_id <> '' LIMIT 100") { room, event in
                    event.map { .gap(room, before: $0) }
                }
                // One per room: a slice around it usually answers for its neighbours too.
                result += try works(
                    "SELECT r.room_id, p.event_id, max(p.rowid) FROM pending p JOIN room r ON r.id = p.room WHERE p.state = 0 AND p.next_at <= ? GROUP BY p.room LIMIT 100",
                    [stamp]) { room, event in event.map { .retry(room, around: $0) } }
                if result.count >= limit { return Array(result.prefix(limit)) }
                let coverage = try Self.coverage(db)
                for room in rooms where result.count < limit {
                    switch coverage[room]?.state {
                    case nil: result.append(.start(room))
                    case .partial?: result.append(coverage[room]?.anchor.map { .history(room, before: $0) } ?? .start(room))
                    case .complete?, .blocked?: break
                    }
                }
                return result
            }
        } catch { throw map(error) }
    }

    public func known(_ events: [EventID], in room: RoomID) async throws(HaloError) -> Set<EventID> {
        guard !events.isEmpty else { return [] }
        let pool = try await database()
        do {
            return try await pool.read { db in
                guard let id = try Self.roomRow(room, create: false, db) else { return [] }
                return Set(try events.filter { try Self.isKnown($0, room: id, db) })
            }
        } catch { throw map(error) }
    }

    public func coverage() async throws(HaloError) -> [RoomID: RoomSearchCoverage] {
        let pool = try await database()
        do { return try await pool.read { try Self.coverage($0) } } catch { throw map(error) }
    }

    private static func coverage(_ db: Database) throws -> [RoomID: RoomSearchCoverage] {
        var result: [RoomID: RoomSearchCoverage] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT r.room_id, c.state, c.anchor, c.oldest FROM coverage c JOIN room r ON r.id = c.room") {
            guard let room = try? RoomID(row["room_id"]) else { continue }
            let anchor: String? = row["anchor"], oldest: Int64? = row["oldest"]
            result[room] = RoomSearchCoverage(
                room: room, state: RoomSearchState(rawValue: row["state"]) ?? .partial, anchor: anchor.flatMap { try? EventID($0) }, oldest: oldest.map(date))
        }
        return result
    }

    public func statistics() async throws(HaloError) -> SearchIndexStatistics {
        let pool = try await database()
        do {
            var result = try await pool.read { db in
                SearchIndexStatistics(
                    messages: try Int.fetchOne(db, sql: "SELECT count(*) FROM event") ?? 0,
                    undecryptable: try Int.fetchOne(db, sql: "SELECT count(*) FROM pending WHERE state = 0") ?? 0)
            }
            for suffix in ["", "-wal"] {
                result.bytes += ((try? FileManager.default.attributesOfItem(atPath: path + suffix))?[.size] as? NSNumber)?.int64Value ?? 0
            }
            return result
        } catch { throw map(error) }
    }

    public func indexedRooms() async throws(HaloError) -> Set<RoomID> {
        let pool = try await database()
        do { return try await pool.read { Set(try String.fetchAll($0, sql: "SELECT room_id FROM room").compactMap { try? RoomID($0) }) } } catch { throw map(error) }
    }
}
