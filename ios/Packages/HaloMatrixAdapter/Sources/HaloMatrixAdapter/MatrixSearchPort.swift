import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Synchronization

/// `SearchPort` over the SDK's `Client.searchService()` (`V-SEARCH-1`, M8).
/// All upstream `SearchServiceResult` / `SearchServiceResultsUpdate` values are mapped immediately in the listener
/// callbacks so no upstream type crosses the adapter boundary (AGENTS.md §4.3, §8).
public final class MatrixSearchPort: SearchPort {
    private struct State {
        var service: SearchService?
        var lastQuery = ""
        var hits: [MessageSearchHit] = []
        var isLoading = false
        var hasMore = false
        var handles: [TaskHandle] = []
        var continuations: [UUID: AsyncStream<SearchSnapshot>.Continuation] = [:]
    }

    private let session: MatrixSessionPort
    private let state = Mutex(State())

    public init(session: MatrixSessionPort) { self.session = session }

    deinit {
        state.withLock { state in
            for handle in state.handles { handle.cancel() }
            state.handles.removeAll()
        }
    }

    public func snapshots() -> AsyncStream<SearchSnapshot> {
        let (stream, continuation) = AsyncStream<SearchSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let current = state.withLock { state -> SearchSnapshot in
            state.continuations[id] = continuation
            return SearchSnapshot(hits: state.hits, isLoading: state.isLoading, hasMore: state.hasMore)
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func setQuery(_ query: String) async throws(HaloError) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        // If re-searching the exact same query (e.g. after new messages arrived or reopening the sheet),
        // recreate the SearchService so the SDK does not treat `setQuery` as a no-op.
        let needsReset = state.withLock { $0.service != nil && $0.lastQuery == trimmed }
        if needsReset { reset() }
        let service = try await ensureService()
        update { state in
            state.lastQuery = trimmed
            state.hits = []
            state.isLoading = true
            state.hasMore = false
        }
        do {
            try await service.setQuery(query: trimmed)
        } catch {
            update { $0.isLoading = false }
            throw ErrorMapper.map(error)
        }
        applyPaginationState(service.paginationState())
    }

    public func loadMore() async throws(HaloError) {
        let service = try await ensureService()
        do {
            try await service.paginate()
        } catch {
            throw ErrorMapper.map(error)
        }
        applyPaginationState(service.paginationState())
    }

    /// Resets the cached `SearchService` (for example on sign-out).
    public func reset() {
        update { state in
            for handle in state.handles { handle.cancel() }
            state.handles.removeAll()
            state.service = nil
            state.lastQuery = ""
            state.hits = []
            state.isLoading = false
            state.hasMore = false
        }
    }

    // MARK: Internals

    private func ensureService() async throws(HaloError) -> SearchService {
        if let existing = state.withLock({ $0.service }) { return existing }
        let client = try await session.signedInClient()
        let service = client.searchService()
        let resultsHandle = await service.subscribeToResults(listener: ResultsListener { [weak self] updates in
            self?.applyResultUpdates(updates)
        })
        let paginationHandle = service.subscribeToPaginationStateUpdates(listener: PaginationListener { [weak self] pagination in
            self?.applyPaginationState(pagination)
        })
        state.withLock { state in
            state.service = service
            state.handles = [resultsHandle, paginationHandle]
        }
        return service
    }

    private func applyPaginationState(_ pagination: SearchServicePaginationState) {
        update { state in
            switch pagination {
            case .loading:
                state.isLoading = true
            case .idle(let endReached):
                state.isLoading = false
                state.hasMore = !endReached
            }
        }
    }

    private func applyResultUpdates(_ updates: [MappedUpdate]) {
        update { state in
            for update in updates {
                switch update {
                case .append(let values):
                    state.hits.append(contentsOf: values)
                case .clear:
                    state.hits.removeAll()
                case .pushFront(let value):
                    state.hits.insert(value, at: 0)
                case .pushBack(let value):
                    state.hits.append(value)
                case .popFront:
                    if !state.hits.isEmpty { state.hits.removeFirst() }
                case .popBack:
                    if !state.hits.isEmpty { state.hits.removeLast() }
                case .insert(let index, let value):
                    let i = min(index, state.hits.count)
                    state.hits.insert(value, at: i)
                case .set(let index, let value):
                    if index < state.hits.count { state.hits[index] = value }
                case .remove(let index):
                    if index < state.hits.count { state.hits.remove(at: index) }
                case .truncate(let length):
                    if length < state.hits.count { state.hits.removeLast(state.hits.count - length) }
                case .reset(let values):
                    state.hits = values
                }
            }
        }
    }

    private func update(_ change: (inout State) -> Void) {
        let (snapshot, continuations) = state.withLock { state -> (SearchSnapshot, [AsyncStream<SearchSnapshot>.Continuation]) in
            change(&state)
            return (SearchSnapshot(hits: state.hits, isLoading: state.isLoading, hasMore: state.hasMore), Array(state.continuations.values))
        }
        for continuation in continuations { continuation.yield(snapshot) }
    }

    fileprivate enum MappedUpdate: Sendable {
        case append([MessageSearchHit])
        case clear
        case pushFront(MessageSearchHit)
        case pushBack(MessageSearchHit)
        case popFront
        case popBack
        case insert(Int, MessageSearchHit)
        case set(Int, MessageSearchHit)
        case remove(Int)
        case truncate(Int)
        case reset([MessageSearchHit])
    }

    fileprivate static func map(_ result: SearchServiceResult) -> MessageSearchHit? {
        switch result {
        case .message(let roomRaw, let msg):
            guard let roomID = try? RoomID(roomRaw), let eventID = try? EventID(msg.eventId) else { return nil }
            let body = MatrixRoomListPort.previewText(msg.content) ?? ""
            let senderName = MatrixRoomListPort.displayName(msg.senderProfile)
            let timestamp = Date(timeIntervalSince1970: Double(msg.timestamp) / 1000)
            return MessageSearchHit(
                roomID: roomID, eventID: eventID, senderID: msg.sender,
                senderName: senderName, body: body, timestamp: timestamp)
        }
    }
}

private final class ResultsListener: SearchServiceResultsListener {
    private let handler: @Sendable ([MatrixSearchPort.MappedUpdate]) -> Void

    init(_ handler: @escaping @Sendable ([MatrixSearchPort.MappedUpdate]) -> Void) {
        self.handler = handler
    }

    func onUpdate(updates: [SearchServiceResultsUpdate]) {
        let mapped: [MatrixSearchPort.MappedUpdate] = updates.compactMap { update in
            switch update {
            case .append(let values): .append(values.compactMap(MatrixSearchPort.map))
            case .clear: .clear
            case .pushFront(let value): MatrixSearchPort.map(value).map { .pushFront($0) }
            case .pushBack(let value): MatrixSearchPort.map(value).map { .pushBack($0) }
            case .popFront: .popFront
            case .popBack: .popBack
            case .insert(let index, let value): MatrixSearchPort.map(value).map { .insert(Int(index), $0) }
            case .set(let index, let value): MatrixSearchPort.map(value).map { .set(Int(index), $0) }
            case .remove(let index): .remove(Int(index))
            case .truncate(let length): .truncate(Int(length))
            case .reset(let values): .reset(values.compactMap(MatrixSearchPort.map))
            }
        }
        handler(mapped)
    }
}

private final class PaginationListener: SearchServicePaginationStateListener {
    private let handler: @Sendable (SearchServicePaginationState) -> Void

    init(_ handler: @escaping @Sendable (SearchServicePaginationState) -> Void) {
        self.handler = handler
    }

    func onUpdate(paginationState: SearchServicePaginationState) {
        handler(paginationState)
    }
}
