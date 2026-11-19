import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPlatform

@Suite("NotificationRecordStore")
struct NotificationRecordStoreTests {
    private func record(_ room: String, _ event: String, ageSeconds: Double = 0) throws -> NotificationRecord {
        NotificationRecord(roomID: try RoomID(room), eventID: try EventID(event), timestamp: Date().addingTimeInterval(-ageSeconds), isMention: false)
    }

    @Test("records are de-duplicated by event, cleared per room, and old ones expire")
    func records() throws {
        let suite = "halo.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = NotificationRecordStore(suiteName: suite)
        #expect(store.add(try record("!a:x.org", "$1")))
        #expect(!store.add(try record("!a:x.org", "$1")))  // the same event again
        #expect(store.add(try record("!a:x.org", "$2")))
        #expect(store.add(try record("!b:x.org", "$3")))
        #expect(store.add(try record("!b:x.org", "$old", ageSeconds: 8 * 24 * 3600)) == true)
        #expect(Set(store.all().map(\.eventID.rawValue)) == ["$1", "$2", "$3"])  // the week-old one is hidden
        store.clear(room: try RoomID("!a:x.org"))
        #expect(store.all().map(\.eventID.rawValue) == ["$3"])
    }

    @Test("a change made by another store instance (the extension) is announced")
    func changes() async throws {
        let suite = "halo.test.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let app = NotificationRecordStore(suiteName: suite)
        let stream = app.changes()
        let waiter = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        NotificationRecordStore(suiteName: suite).add(try record("!a:x.org", "$1"))
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); waiter.cancel() }
        let fired = await waiter.value
        timeout.cancel()
        #expect(fired)
    }
}
