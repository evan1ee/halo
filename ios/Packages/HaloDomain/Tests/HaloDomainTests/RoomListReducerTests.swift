import HaloFoundation
import Testing
@testable import HaloDomain

private func room(_ n: Int) -> RoomSummary {
    RoomSummary(id: try! RoomID("!r\(n):halo.localhost"), name: "Room \(n)", isDirect: false, isEncrypted: true, membership: .joined)
}

@Suite("RoomListReducer")
struct RoomListReducerTests {
    @Test("each diff kind")
    func eachKind() throws {
        var list: [RoomSummary] = []
        try RoomListReducer.apply(.append([room(1), room(2)]), to: &list)
        try RoomListReducer.apply(.pushFront(room(0)), to: &list)
        try RoomListReducer.apply(.pushBack(room(3)), to: &list)
        #expect(list.map(\.name) == ["Room 0", "Room 1", "Room 2", "Room 3"])
        try RoomListReducer.apply(.insert(index: 4, room(4)), to: &list)
        try RoomListReducer.apply(.set(index: 0, room(9)), to: &list)
        try RoomListReducer.apply(.remove(index: 1), to: &list)
        #expect(list.map(\.name) == ["Room 9", "Room 2", "Room 3", "Room 4"])
        try RoomListReducer.apply(.popFront, to: &list)
        try RoomListReducer.apply(.popBack, to: &list)
        try RoomListReducer.apply(.truncate(length: 1), to: &list)
        #expect(list.map(\.name) == ["Room 2"])
        try RoomListReducer.apply(.truncate(length: 5), to: &list)
        #expect(list.count == 1)
        try RoomListReducer.apply(.reset([room(7), room(8)]), to: &list)
        #expect(list.count == 2)
        try RoomListReducer.apply(.clear, to: &list)
        #expect(list.isEmpty)
    }

    @Test("out-of-range diffs throw and leave the list unchanged", arguments: [
        RoomListDiff.popFront, .popBack, .insert(index: 2, room(5)), .insert(index: -1, room(5)),
        .set(index: 1, room(5)), .remove(index: 1), .remove(index: -1), .truncate(length: -1),
    ])
    func outOfRange(diff: RoomListDiff) throws {
        var list = diff == .popFront || diff == .popBack ? [] : [room(1)]
        let before = list
        #expect(throws: HaloError.internal(code: "ROOM_LIST_DIFF_OUT_OF_RANGE")) {
            try RoomListReducer.apply(diff, to: &list)
        }
        #expect(list == before)
    }

    /// Differential property test: random valid diffs applied by the reducer give the same list as
    /// a model that performs the same edits with `replaceSubrange` (TEST_STRATEGY §1, seed printed).
    @Test("random valid diff sequences match a replaceSubrange model")
    func property() throws {
        for seed in UInt64(1)...200 {
            var rng = SeededRandomNumberGenerator(seed: seed)
            var list: [RoomSummary] = [], model: [RoomSummary] = []
            var next = 0
            func fresh() -> RoomSummary { next += 1; return room(next) }
            for _ in 0..<60 {
                let (diff, edit) = randomDiff(count: model.count, fresh: fresh, rng: &rng)
                try RoomListReducer.apply(diff, to: &list)
                edit(&model)
                #expect(list == model, "seed \(seed)")
                if list != model { return }
            }
        }
    }

    private func randomDiff(
        count: Int, fresh: () -> RoomSummary, rng: inout SeededRandomNumberGenerator
    ) -> (RoomListDiff, (inout [RoomSummary]) -> Void) {
        let kind = Int.random(in: 0..<11, using: &rng)
        let index = count == 0 ? 0 : Int.random(in: 0..<count, using: &rng)
        switch (kind, count) {
        case (0, _):
            let values = (0..<Int.random(in: 0...3, using: &rng)).map { _ in fresh() }
            return (.append(values), { $0.replaceSubrange($0.endIndex..<$0.endIndex, with: values) })
        case (1, _): return (.clear, { $0.replaceSubrange($0.startIndex..<$0.endIndex, with: []) })
        case (2, _): let v = fresh(); return (.pushFront(v), { $0.replaceSubrange(0..<0, with: [v]) })
        case (4, 1...): return (.popFront, { $0.replaceSubrange(0..<1, with: []) })
        case (5, 1...): return (.popBack, { $0.replaceSubrange(($0.count - 1)..<$0.count, with: []) })
        case (6, _):
            let at = Int.random(in: 0...count, using: &rng), v = fresh()
            return (.insert(index: at, v), { $0.replaceSubrange(at..<at, with: [v]) })
        case (7, 1...): let v = fresh(); return (.set(index: index, v), { $0.replaceSubrange(index...index, with: [v]) })
        case (8, 1...): return (.remove(index: index), { $0.replaceSubrange(index...index, with: []) })
        case (9, _):
            let length = Int.random(in: 0...(count + 2), using: &rng)
            return (.truncate(length: length), { if length < $0.count { $0.replaceSubrange(length..<$0.count, with: []) } })
        case (10, _):
            let values = (0..<Int.random(in: 0...5, using: &rng)).map { _ in fresh() }
            return (.reset(values), { $0.replaceSubrange($0.startIndex..<$0.endIndex, with: values) })
        default: let v = fresh(); return (.pushBack(v), { $0.replaceSubrange($0.endIndex..<$0.endIndex, with: [v]) })
        }
    }
}

@Suite("Domain models")
struct DomainModelTests {
    @Test("credentials and sessions never print secrets")
    func redaction() throws {
        let credentials = PasswordCredentials(username: "alice", password: "hunter2", deviceDisplayName: "Halo (iPhone)")
        #expect(!"\(credentials)".contains("hunter2"))
        let session = StoredSession(userID: try UserID("@alice:halo.localhost"), deviceID: try DeviceID("DEV"), payload: .init("tok".utf8))
        #expect("\(session)" == "StoredSession(<redacted>)")
    }
}
