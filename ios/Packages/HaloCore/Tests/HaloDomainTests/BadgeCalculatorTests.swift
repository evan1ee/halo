import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("BadgeCalculator (D9, D82): the one place per-room counts and totals are made")
struct BadgeCalculatorTests {
    private let a = try! RoomID("!a:x.org")
    private let b = try! RoomID("!b:x.org")
    private let c = try! RoomID("!c:x.org")

    private func state(_ room: RoomID, attention: Bool, count: Int) -> RoomReadState {
        RoomReadState(
            roomID: room, attention: attention, hasUnread: attention,
            display: attention ? (count > 0 ? .count(count) : .dot) : .none,
            confidence: .exact, badgeCount: count, reasons: [])
    }

    @Test("a room counts its messages, at least one, only while it needs attention")
    func roomCount() {
        #expect(BadgeCalculator.roomCount(state(a, attention: true, count: 4)) == 4)
        #expect(BadgeCalculator.roomCount(state(a, attention: true, count: 0)) == 1)
        #expect(BadgeCalculator.roomCount(state(a, attention: false, count: 7)) == 0)
    }

    @Test("the total of stored counts ignores zero and negative entries")
    func total() {
        #expect(BadgeCalculator.total([RoomID: Int]()) == 0)
        #expect(BadgeCalculator.total([a: 3, b: 0, c: 2]) == 5)
        #expect(BadgeCalculator.total(["x": -2, "y": 4]) == 4)
    }

    @Test("attention counts: evaluated rooms, then unlisted pushes, then carried counts (larger wins), minus excluded")
    func attentionCounts() {
        let evaluated = [state(a, attention: true, count: 2), state(b, attention: false, count: 0)]
        // A push for listed room B is already in B's evaluation; two pushes for unlisted C count two.
        let counts = BadgeCalculator.attentionCounts(evaluated: evaluated, unlistedRecords: [b, c, c])
        #expect(counts == [a: 2, c: 2])
        // A carried count never adds to an evaluated one: the larger stays.
        #expect(BadgeCalculator.attentionCounts(evaluated: evaluated, carried: [a: 5]) == [a: 5])
        #expect(BadgeCalculator.attentionCounts(evaluated: evaluated, carried: [a: 1, c: 0]) == [a: 2])
        // Excluded rooms never count, whatever the source.
        #expect(BadgeCalculator.attentionCounts(evaluated: evaluated, unlistedRecords: [c], carried: [a: 9], excluded: [a, c]).isEmpty)
        #expect(BadgeCalculator.badge(evaluated) == BadgeCalculator.total(BadgeCalculator.attentionCounts(evaluated: evaluated)))
    }

    @Test("the extension's fallback adds the new pushes' worth to the app's last count")
    func countAfterUnsyncedPushes() {
        #expect(BadgeCalculator.countAfterUnsyncedPushes(lastEvaluated: 3, pushes: state(a, attention: true, count: 2)) == 5)
        #expect(BadgeCalculator.countAfterUnsyncedPushes(lastEvaluated: 0, pushes: state(a, attention: true, count: 0)) == 1)
    }
}
