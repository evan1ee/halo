import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPersistence

@Suite("NotificationRecordStore (GRDB, R-13)")
struct NotificationRecordStoreTests {
    private func database() throws -> (HaloDatabase, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("halo-nr-\(UUID().uuidString).sqlite").path
        return (try HaloDatabase(path: path), path)
    }

    private func record(
        _ room: String, _ event: String, ts: Double = 1_000, deliveredAt: Date = Date(),
        mention: Bool = false, source: NotificationRecord.Source = .nse
    ) throws -> NotificationRecord {
        NotificationRecord(
            roomID: try RoomID(room), eventID: try EventID(event),
            timestamp: Date(timeIntervalSince1970: ts), isMention: mention,
            deliveredAt: deliveredAt, source: source)
    }

    @Test("de-duplicates by event ID, preserves event timestamp and source, expires old deliveries, and clears per room/rooms/events/all")
    func lifecycle() throws {
        let (db, _) = try database()
        let now = Date(timeIntervalSince1970: 10_000_000)
        let store = NotificationRecordStore(database: db, account: try UserID("@alice:x.org"), now: { now })

        let e1 = try record("!a:x.org", "$1", ts: 500, deliveredAt: now, mention: true, source: .nse)
        #expect(store.add(e1))
        #expect(!store.add(e1))  // duplicate push (AC-U7)
        #expect(store.add(try record("!a:x.org", "$2", ts: 600, deliveredAt: now, source: .app)))
        #expect(store.add(try record("!b:x.org", "$3", ts: 700, deliveredAt: now)))
        #expect(store.add(try record("!c:x.org", "$4", ts: 800, deliveredAt: now)))
        // Older than 7 days: hidden from all() and pruned on next write.
        _ = store.add(try record("!b:x.org", "$old", ts: 100, deliveredAt: now.addingTimeInterval(-8 * 24 * 3600)))

        let loaded = store.all()
        #expect(loaded.map(\.eventID.rawValue) == ["$1", "$2", "$3", "$4"])
        #expect(loaded.first == e1)

        store.remove(events: [try EventID("$1")])
        #expect(store.all().map(\.eventID.rawValue) == ["$2", "$3", "$4"])

        store.clear(rooms: [try RoomID("!a:x.org"), try RoomID("!c:x.org")])
        #expect(store.all().map(\.eventID.rawValue) == ["$3"])

        store.clearAll()
        #expect(store.all().isEmpty)
    }

    @Test("PS27: records are scoped by account, so signing in as B never sees A's records")
    func accountIsolation() throws {
        let (db, _) = try database()
        let now = Date(timeIntervalSince1970: 10_000_000)
        let alice = NotificationRecordStore(database: db, account: try UserID("@alice:x.org"), now: { now })
        let bob = NotificationRecordStore(database: db, account: try UserID("@bob:x.org"), now: { now })

        #expect(alice.add(try record("!a:x.org", "$1", deliveredAt: now)))
        #expect(bob.all().isEmpty)
        #expect(bob.add(try record("!b:x.org", "$1", deliveredAt: now)))  // same event ID in another account's scope
        #expect(alice.all().map(\.roomID.rawValue) == ["!a:x.org"])
        #expect(bob.all().map(\.roomID.rawValue) == ["!b:x.org"])

        alice.clearAll()
        #expect(alice.all().isEmpty)
        #expect(bob.all().map(\.roomID.rawValue) == ["!b:x.org"])
    }

    @Test("PS33: concurrent NSE adds and app clears on one database never resurrect a cleared record (R-13)")
    func concurrentAddAndClearNeverResurrects() async throws {
        let (_, path) = try database()
        let now = Date(timeIntervalSince1970: 10_000_000)
        let user = try UserID("@alice:x.org")
        let appDB = try HaloDatabase(path: path)
        let nseDB = try HaloDatabase(path: path)
        let appStore = NotificationRecordStore(database: appDB, account: user, now: { now })
        let nseStore = NotificationRecordStore(database: nseDB, account: user, now: { now })

        let clearedRoom = try RoomID("!cleared:x.org")
        let activeRoom = try RoomID("!active:x.org")
        for i in 0..<50 {
            #expect(nseStore.add(try record(clearedRoom.rawValue, "$old\(i)", ts: Double(i), deliveredAt: now)))
        }

        // Interleave app clearing `clearedRoom` with NSE inserting new records into `activeRoom` from a second pool.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<100 {
                    _ = nseStore.add(NotificationRecord(
                        roomID: activeRoom, eventID: try! EventID("$new\(i)"),
                        timestamp: Date(timeIntervalSince1970: Double(1000 + i)), isMention: false, deliveredAt: now))
                }
            }
            group.addTask {
                appStore.clear(room: clearedRoom)
            }
        }

        let remaining = appStore.all()
        #expect(remaining.filter { $0.roomID == clearedRoom }.isEmpty)
        #expect(remaining.filter { $0.roomID == activeRoom }.count == 100)
    }
}
