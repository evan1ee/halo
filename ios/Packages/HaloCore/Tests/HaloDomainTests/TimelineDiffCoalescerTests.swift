import HaloFoundation
import Testing

@testable import HaloDomain

@Suite("Timeline diff coalescing: a confirmed echo stays one row")
struct TimelineDiffCoalescerTests {
    private func item(_ id: String, sent: Bool = false) -> TimelineItem {
        TimelineItem(id: TimelineItemID(id), content: .virtual(sent ? .readMarker : .timelineStart))
    }

    /// Applies the batches the way the coordinator does and returns what a list view would have seen after each diff.
    private func shown(_ diffs: [TimelineDiff], from start: [TimelineItem]) throws -> [[String]] {
        var items = start
        var states: [[String]] = []
        for diff in diffs {
            try ListReducer.apply(diff, to: &items)
            states.append(items.map(\.id.rawValue))
        }
        return states
    }

    @Test("remove + pushBack of the same ID at the same place becomes one set")
    func removeThenPushBackIsSet() throws {
        var coalescer = TimelineDiffCoalescer()
        let list = [item("1"), item("2"), item("33")]
        _ = coalescer.coalesce([.reset(list)])
        let out = coalescer.coalesce([.remove(index: 2), .pushBack(item("33", sent: true))])
        #expect(out == [.set(index: 2, item("33", sent: true))])
        let states = try shown(out, from: list)
        #expect(states.allSatisfy { $0 == ["1", "2", "33"] }, "the row is never missing")
    }

    @Test("remove + insert at the same index is a set; a different index is a real move and is kept")
    func insertAndMove() throws {
        var coalescer = TimelineDiffCoalescer()
        _ = coalescer.coalesce([.reset([item("a"), item("b"), item("c")])])
        #expect(coalescer.coalesce([.remove(index: 1), .insert(index: 1, item("b", sent: true))]) == [.set(index: 1, item("b", sent: true))])
        let move = coalescer.coalesce([.remove(index: 0), .pushBack(item("a"))])
        #expect(move == [.remove(index: 0), .pushBack(item("a"))])
    }

    @Test("a different ID, a plain remove, and a remove at the end of the batch pass through in order")
    func passThrough() {
        var coalescer = TimelineDiffCoalescer()
        _ = coalescer.coalesce([.reset([item("a"), item("b")])])
        #expect(coalescer.coalesce([.remove(index: 1), .pushBack(item("z"))]) == [.remove(index: 1), .pushBack(item("z"))])
        #expect(coalescer.coalesce([.remove(index: 1)]) == [.remove(index: 1)])
        #expect(coalescer.coalesce([.pushBack(item("q")), .remove(index: 0)]) == [.pushBack(item("q")), .remove(index: 0)])
    }

    @Test("the mirror follows every diff kind, so later pairs are still recognised")
    func mirrorStaysInStep() {
        var coalescer = TimelineDiffCoalescer()
        _ = coalescer.coalesce([
            .reset([item("a")]), .append([item("b"), item("c")]), .pushFront(item("z")), .insert(index: 2, item("m")),
            .set(index: 0, item("z")), .popFront, .truncate(length: 3),
        ])
        // a, m, b are left (z popped, c truncated).
        #expect(coalescer.coalesce([.remove(index: 2), .pushBack(item("b", sent: true))]) == [.set(index: 2, item("b", sent: true))])
        _ = coalescer.coalesce([.clear])
        #expect(coalescer.coalesce([.remove(index: 0)]) == [.remove(index: 0)], "unknown index passes through for the reducer to report")
    }

    @Test("two pairs in one batch are both folded")
    func twoPairs() {
        var coalescer = TimelineDiffCoalescer()
        _ = coalescer.coalesce([.reset([item("a"), item("b")])])
        let out = coalescer.coalesce([.remove(index: 1), .pushBack(item("b", sent: true)), .remove(index: 1), .pushBack(item("b"))])
        #expect(out == [.set(index: 1, item("b", sent: true)), .set(index: 1, item("b"))])
    }
}
