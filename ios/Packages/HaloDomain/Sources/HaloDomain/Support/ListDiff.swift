import HaloFoundation

/// One change to an ordered list. Mirrors the upstream list diffs one to one (Append, Clear, PushFront,
/// PushBack, PopFront, PopBack, Insert, Set, Remove, Truncate, Reset), so adapters map without
/// reinterpreting. Diffs are incremental and must never be dropped (CONCURRENCY §3).
public enum ListDiff<Element: Sendable>: Sendable {
    case append([Element])
    case clear
    case pushFront(Element)
    case pushBack(Element)
    case popFront
    case popBack
    case insert(index: Int, Element)
    case set(index: Int, Element)
    case remove(index: Int)
    case truncate(length: Int)
    case reset([Element])
}

extension ListDiff: Equatable where Element: Equatable {}

public enum ListReducer {
    /// Applies `diff` to `items`. A diff that doesn't fit the current list (index out of range, pop from an
    /// empty list) leaves `items` unchanged and throws `.internal(code: "LIST_DIFF_OUT_OF_RANGE")`: the list
    /// and its source disagree, and the caller must resubscribe to get a `.reset`.
    public static func apply<Element>(_ diff: ListDiff<Element>, to items: inout [Element]) throws(HaloError) {
        switch diff {
        case .append(let values): items.append(contentsOf: values)
        case .clear: items.removeAll()
        case .pushFront(let value): items.insert(value, at: 0)
        case .pushBack(let value): items.append(value)
        case .popFront:
            guard !items.isEmpty else { throw outOfRange }
            items.removeFirst()
        case .popBack:
            guard !items.isEmpty else { throw outOfRange }
            items.removeLast()
        case .insert(let index, let value):
            guard (0...items.count).contains(index) else { throw outOfRange }
            items.insert(value, at: index)
        case .set(let index, let value):
            guard items.indices.contains(index) else { throw outOfRange }
            items[index] = value
        case .remove(let index):
            guard items.indices.contains(index) else { throw outOfRange }
            items.remove(at: index)
        case .truncate(let length):
            guard length >= 0 else { throw outOfRange }
            if length < items.count { items.removeLast(items.count - length) }
        case .reset(let values): items = values
        }
    }

    private static var outOfRange: HaloError { .internal(code: "LIST_DIFF_OUT_OF_RANGE") }
}
