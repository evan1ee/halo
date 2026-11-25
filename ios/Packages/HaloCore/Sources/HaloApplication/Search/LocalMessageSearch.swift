import Foundation
import HaloDomain
import HaloFoundation

/// `SearchPort` over Halo's own index (ADR-0024). Every page is checked against the SDK before it is shown (MESSAGE_SEARCH FR-11): deleted
/// messages leave the index and the page, edited ones show their new text. Ignored people and rooms that aren't joined are left out.
public actor LocalMessageSearch: SearchPort {
    public static let pageSize = 25
    /// A slow or missing network doesn't hold results back longer than this; what wasn't checked by then is shown as the index has it.
    public static let recheckTimeout: Duration = .milliseconds(1_200)
    static let concurrentRechecks = 6

    private let index: any LocalSearchIndexPort
    private let source: any MessageIndexSourcePort
    private let joined: @Sendable () async -> Set<RoomID>
    private let ignored: @Sendable () async -> Set<UserID>
    private let now: @Sendable () -> Date
    private let sleep: SearchCoordinator.Sleep

    public init(
        index: any LocalSearchIndexPort, source: any MessageIndexSourcePort, joined: @escaping @Sendable () async -> Set<RoomID>,
        ignored: @escaping @Sendable () async -> Set<UserID>, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping SearchCoordinator.Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.index = index
        self.source = source
        self.joined = joined
        self.ignored = ignored
        self.now = now
        self.sleep = sleep
    }

    public func search(_ query: SearchQuery, after cursor: SearchCursor?) async throws(HaloError) -> SearchPage {
        guard let match = SearchTokeniser.matchExpression(query.text) else { return SearchPage(hits: [], next: nil) }
        let hidden = await ignored(), rooms = await joined()
        var cursor = cursor
        // A page can lose rows to the checks; a page without any left goes on to the next.
        for _ in 0..<10 {
            if Task.isCancelled { throw .cancelled }
            let found = try await index.hits(
                match: match, room: query.room, kinds: query.filter.kinds, excluding: hidden, after: cursor, limit: Self.pageSize)
            let next = found.count == Self.pageSize ? found.last?.cursor : nil
            let shown = try await checked(found.filter { rooms.contains($0.entry.room) })
            if !shown.isEmpty || next == nil { return SearchPage(hits: shown, next: next) }
            cursor = next
        }
        return SearchPage(hits: [], next: cursor)
    }

    private func checked(_ found: [SearchIndexHit]) async throws(HaloError) -> [MessageSearchHit] {
        let due = now().addingTimeInterval(-SearchIndexPolicy.recheckInterval)
        let results = await recheck(found.filter { $0.checkedAt < due }.map { ($0.entry.room, $0.entry.event) })
        if Task.isCancelled { throw .cancelled }
        // Not shown any more either way; a failed write only means asking again.
        if !results.isEmpty { try? await index.record(results.map { ($0.key.room, $0.key.event, $0.value) }) }  // best-effort: the index repairs itself: the next pass redoes what is missing
        return found.compactMap { hit in
            let entry = hit.entry
            var content = entry.content
            switch results[Key(room: entry.room, event: entry.event)] {
            case .gone: return nil
            case .edited(let new): content = new
            case .unchanged, .unchecked, nil: break
            }
            return MessageSearchHit(
                roomID: entry.room, eventID: entry.event, threadRoot: entry.threadRoot, senderID: entry.sender.rawValue, senderName: entry.senderName,
                body: content.body, timestamp: entry.timestamp, kind: content.kind)
        }
    }

    private struct Key: Hashable, Sendable {
        let room: RoomID
        let event: EventID
    }

    /// The answers that arrive in time; errors count as no answer. Not a task group: that would wait for calls into the SDK that can't
    /// be cancelled (it retries for a long time while offline).
    private func recheck(_ events: [(RoomID, EventID)]) async -> [Key: SearchRecheck] {
        guard !events.isEmpty else { return [:] }
        let source = source, wait = sleep
        let keys = events.map { Key(room: $0.0, event: $0.1) }
        let (answers, continuation) = AsyncStream<(key: Key, result: SearchRecheck)>.makeStream()
        let lanes = (0..<min(Self.concurrentRechecks, keys.count)).map { lane in
            Task {
                for index in stride(from: lane, to: keys.count, by: Self.concurrentRechecks) {
                    if Task.isCancelled { return }
                    continuation.yield((keys[index], await Self.answer(source, keys[index])))
                }
            }
        }
        let deadline = Task { [timeout = Self.recheckTimeout] in
            try? await wait(timeout)  // best-effort: the index repairs itself: the next pass redoes what is missing
            continuation.finish()
        }
        defer { for task in lanes + [deadline] { task.cancel() } }
        var results: [Key: SearchRecheck] = [:]
        var answered = 0
        for await answer in answers {
            if answer.result != .unchecked { results[answer.key] = answer.result }
            answered += 1
            if answered == keys.count { break }
        }
        return results
    }

    private static func answer(_ source: any MessageIndexSourcePort, _ key: Key) async -> SearchRecheck {
        do { return try await source.recheck(key.event, in: key.room) } catch { return error == .notFound ? .gone : .unchecked }
    }
}
