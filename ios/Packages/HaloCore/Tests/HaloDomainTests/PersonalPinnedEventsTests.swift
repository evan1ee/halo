import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("PersonalPinnedEvents")
struct PersonalPinnedEventsTests {
    @Test("pinning and unpinning store per-room pins and respect newer schema versions")
    func roundTrip() throws {
        let roomA = try RoomID("!a:x.org")
        let roomB = try RoomID("!b:x.org")
        let e1 = try EventID("$e1")
        let e2 = try EventID("$e2")

        let first = try #require(PersonalPinnedEvents.pinning(e1, in: roomA, content: nil))
        let second = try #require(PersonalPinnedEvents.pinning(e2, in: roomA, content: first))
        let third = try #require(PersonalPinnedEvents.pinning(e1, in: roomB, content: second))

        #expect(PersonalPinnedEvents.pinned(in: roomA, from: third) == [e1, e2])
        #expect(PersonalPinnedEvents.pinned(in: roomB, from: third) == [e1])

        let removed = try #require(PersonalPinnedEvents.unpinning(e1, in: roomA, content: third))
        #expect(PersonalPinnedEvents.pinned(in: roomA, from: removed) == [e2])
        #expect(PersonalPinnedEvents.pinned(in: roomB, from: removed) == [e1])
        #expect(PersonalPinnedEvents.unpinning(e1, in: roomA, content: removed) == nil)

        // Newer version is left untouched.
        let future: [String: Any] = ["version": 2, "rooms": [roomA.rawValue: [e1.rawValue]]]
        #expect(PersonalPinnedEvents.pinning(e2, in: roomA, content: future) == nil)
        #expect(PersonalPinnedEvents.unpinning(e1, in: roomA, content: future) == nil)
    }
}
