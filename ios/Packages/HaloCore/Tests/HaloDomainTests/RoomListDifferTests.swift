import Foundation
import HaloFoundation
import Testing
@testable import HaloDomain

@Suite("RoomListDiffer (M19-3)")
struct RoomListDifferTests {
    private func room(_ n: Int, name: String? = nil, unread: Bool = false) -> RoomSummary {
        RoomSummary(id: try! RoomID("!r\(n):halo.localhost"), name: name ?? "Room \(n)", isDirect: false, isEncrypted: true, membership: .joined)
    }

    private func applied(_ diffs: [RoomListDiff], to old: [RoomSummary]) throws -> [RoomSummary] {
        var rooms = old
        for diff in diffs { try RoomListReducer.apply(diff, to: &rooms) }
        return rooms
    }

    @Test("nothing changed: no diffs; the first list is a reset")
    func unchanged() {
        let rooms = (1...5).map { room($0) }
        #expect(RoomListDiffer.diffs(from: rooms, to: rooms).isEmpty)
        #expect(RoomListDiffer.diffs(from: [], to: rooms) == [.reset(rooms)])
        #expect(RoomListDiffer.diffs(from: [], to: []).isEmpty)
    }

    @Test("among 1,000 rooms one room's change is one set, a new message moving a room up is a remove and an insert")
    func smallChanges() throws {
        let old = (1...1000).map { room($0) }
        var changed = old
        changed[600] = room(601, name: "Renamed")
        let set = RoomListDiffer.diffs(from: old, to: changed)
        #expect(set == [.set(index: 600, changed[600])])

        var moved = old
        let mover = moved.remove(at: 700)
        moved.insert(mover, at: 0)
        let move = RoomListDiffer.diffs(from: old, to: moved)
        #expect(move.count == 2, "\(move.count) operations")
        #expect(try applied(move, to: old) == moved)

        var added = old
        added.insert(room(5000), at: 0)
        #expect(RoomListDiffer.diffs(from: old, to: added) == [.insert(index: 0, room(5000))])
        var removed = old
        removed.remove(at: 10)
        #expect(RoomListDiffer.diffs(from: old, to: removed) == [.remove(index: 10)])
    }

    @Test("a move and a change together keep the order and the new values")
    func moveAndChange() throws {
        let old = (1...10).map { room($0) }
        var new = old
        let mover = new.remove(at: 8)
        new.insert(room(9, name: "Changed"), at: 1)
        _ = mover
        #expect(try applied(RoomListDiffer.diffs(from: old, to: new), to: old) == new)
    }

    @Test("a reshuffle bigger than half the list is one reset")
    func reshuffle() throws {
        let old = (1...100).map { room($0) }
        let new = Array(old.reversed())
        #expect(RoomListDiffer.diffs(from: old, to: new) == [.reset(new)])
    }

    @Test("for any two lists, applying the diffs to the old one gives the new one, with no room twice")
    func property() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let pool = Array(1...40).shuffled(using: &generator)
            let old = pool.prefix(Int.random(in: 0...30, using: &generator)).map { room($0) }
            var other = Array(1...40).shuffled(using: &generator).prefix(Int.random(in: 0...30, using: &generator)).map { room($0) }
            if Bool.random(using: &generator), !other.isEmpty { other[0] = room(Int.random(in: 1...40, using: &generator), name: "x") }
            // A list never has a room twice, whatever the SDK sends.
            var seen: Set<RoomID> = []
            other = other.filter { seen.insert($0.id).inserted }
            let result = try applied(RoomListDiffer.diffs(from: old, to: other), to: old)
            #expect(result == other)
            #expect(Set(result.map(\.id)).count == result.count)
        }
    }
}
