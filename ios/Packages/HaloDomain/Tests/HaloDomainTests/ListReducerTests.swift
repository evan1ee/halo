import HaloFoundation
import Testing
@testable import HaloDomain

@Suite("ListReducer")
struct ListReducerTests {
    /// A tiny deterministic generator: no sleeps, no real randomness (AGENTS.md §12).
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    @Test("random diff sequences match a reference model, and diffs that don't fit leave the list unchanged")
    func randomised() throws {
        var random = LCG(state: 42)
        var list: [Int] = []
        var model: [Int] = []
        for step in 0..<2_000 {
            let diff: ListDiff<Int>
            switch random.next(11) {
            case 0: diff = .append([step, step + 1])
            case 1: diff = .clear
            case 2: diff = .pushFront(step)
            case 3: diff = .pushBack(step)
            case 4: diff = .popFront
            case 5: diff = .popBack
            case 6: diff = .insert(index: random.next(model.count + 3), step)
            case 7: diff = .set(index: random.next(model.count + 3), step)
            case 8: diff = .remove(index: random.next(model.count + 3))
            case 9: diff = .truncate(length: random.next(model.count + 3))
            default: diff = .reset([step])
            }
            let fits = Self.reference(diff, &model)
            let before = list
            if fits {
                try ListReducer.apply(diff, to: &list)
            } else {
                #expect(throws: HaloError.internal(code: "LIST_DIFF_OUT_OF_RANGE")) { try ListReducer.apply(diff, to: &list) }
                #expect(list == before)
            }
            #expect(list == model)
        }
    }

    /// The same semantics written the obvious way; returns false (leaving `model` alone) when the diff doesn't fit.
    private static func reference(_ diff: ListDiff<Int>, _ model: inout [Int]) -> Bool {
        switch diff {
        case .append(let v): model += v
        case .clear: model = []
        case .pushFront(let v): model = [v] + model
        case .pushBack(let v): model = model + [v]
        case .popFront: if model.isEmpty { return false }; model = Array(model.dropFirst())
        case .popBack: if model.isEmpty { return false }; model = Array(model.dropLast())
        case .insert(let i, let v):
            if i < 0 || i > model.count { return false }
            model = Array(model[..<i]) + [v] + Array(model[i...])
        case .set(let i, let v): if !model.indices.contains(i) { return false }; model[i] = v
        case .remove(let i): if !model.indices.contains(i) { return false }; model.remove(at: i)
        case .truncate(let n): if n < 0 { return false }; model = Array(model.prefix(n))
        case .reset(let v): model = v
        }
        return true
    }
}
