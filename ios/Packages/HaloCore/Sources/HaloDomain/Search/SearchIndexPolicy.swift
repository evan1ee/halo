import Foundation
import HaloFoundation

/// The decisions of the search indexer (MESSAGE_SEARCH FR-9, FR-10; ADR-0024): pure, so they can be tested without an SDK or a clock.
public enum SearchIndexPolicy {
    /// Events per history slice (pages of 100).
    public static let pagesPerSlice = 5
    /// A client of its own is dropped after this many rooms or events: the SDK never drops what an event-focused timeline loaded (F-FFI-26).
    public static let roomsPerClient = 20
    public static let eventsPerClient = 5_000
    /// How many of a room's newest events are compared with the index when it may have missed some.
    public static let checkedEvents = 30
    /// This many messages of one room in one sync response may hide more: the server sends at most ten events per room.
    public static let suspiciousCount = 5
    /// A hit the SDK was asked about more recently than this is shown without asking again.
    public static let recheckInterval: TimeInterval = 3_600

    public enum Pause: String, Sendable, Equatable, CaseIterable {
        case user, lowPower, hot, mobileData, offline, busy, background, storageFull
    }

    public struct Conditions: Sendable, Equatable {
        public var pausedByUser = false
        public var lowPower = false
        public var isHot = false
        public var onMobileData = false
        public var mobileDataAllowed = false
        public var offline = false
        public var isBusy = false
        /// The app may read history: it is in front, or a processing task runs.
        public var mayRun = true

        public init(pausedByUser: Bool = false, lowPower: Bool = false, isHot: Bool = false, onMobileData: Bool = false, mobileDataAllowed: Bool = false, offline: Bool = false, isBusy: Bool = false, mayRun: Bool = true) {
            self.pausedByUser = pausedByUser
            self.lowPower = lowPower
            self.isHot = isHot
            self.onMobileData = onMobileData
            self.mobileDataAllowed = mobileDataAllowed
            self.offline = offline
            self.isBusy = isBusy
            self.mayRun = mayRun
        }
    }

    /// Why history isn't read now; `nil` when it may be.
    public static func pause(_ conditions: Conditions) -> Pause? {
        if conditions.pausedByUser { return .user }
        if !conditions.mayRun { return .background }
        if conditions.offline { return .offline }
        if conditions.lowPower { return .lowPower }
        if conditions.isHot { return .hot }
        if conditions.onMobileData && !conditions.mobileDataAllowed { return .mobileData }
        if conditions.isBusy { return .busy }
        return nil
    }

    /// Rooms of a batch whose newest events must be compared with the server (they may have missed messages).
    public static func roomsToCheck(_ batch: SearchLiveBatch) -> Set<RoomID> {
        if batch.isCatchUp { return batch.touched.subtracting(batch.left) }
        var counts: [RoomID: Int] = [:]
        for event in batch.events { counts[event.room, default: 0] += 1 }
        return Set(counts.filter { $0.value >= suspiciousCount }.keys)
    }

    public enum GapStart: Sendable, Equatable {
        case none
        case from(EventID)
        /// Everything newer than the missing message is in threads: start at the room's newest event.
        case newest
    }

    /// Where to read a room's missing messages from, given its newest ones (newest first): the first unknown message, or the next newer
    /// one outside a thread.
    public static func gapStart(recent: [SearchRecentMessage], known: Set<EventID>) -> GapStart {
        guard let missing = recent.firstIndex(where: { !known.contains($0.event) }) else { return .none }
        guard let start = recent[...missing].last(where: { !$0.isThreaded }) else { return .newest }
        return .from(start.event)
    }

    /// How long to wait before asking for a message's key again: one minute, doubling up to half a day.
    public static func retryDelay(attempts: Int) -> TimeInterval { min(60 * pow(2, Double(max(0, attempts - 1))), 43_200) }

    /// Pause after a failed slice: 5 s doubling up to five minutes.
    public static func backoff(afterFailures failures: Int) -> Duration { .seconds(min(300, 5 << min(max(failures - 1, 0), 6))) }

    /// The oldest date up to which every room is searchable: the newest "oldest message" among the rooms still being read. `nil` while a
    /// room hasn't been read at all, or when all are complete.
    public static func searchedBackTo(_ rooms: [RoomID], coverage: [RoomID: RoomSearchCoverage]) -> Date? {
        var result: Date?
        for room in rooms {
            guard let state = coverage[room] else { return nil }
            guard state.state == .partial else { continue }
            guard let oldest = state.oldest else { return nil }
            result = max(result ?? oldest, oldest)
        }
        return result
    }
}

/// What the indexer is doing and how far it got (MESSAGE_SEARCH FR-13).
public struct SearchIndexStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case stopped
        case indexing
        case paused(SearchIndexPolicy.Pause)
        case done
        /// The index can't be opened now (the phone is locked).
        case unavailable
    }

    public var phase: Phase
    public var completeRooms: Int
    public var totalRooms: Int
    public var searchedBackTo: Date?
    public var statistics: SearchIndexStatistics

    public init(phase: Phase = .stopped, completeRooms: Int = 0, totalRooms: Int = 0, searchedBackTo: Date? = nil, statistics: SearchIndexStatistics = .init()) {
        self.phase = phase
        self.completeRooms = completeRooms
        self.totalRooms = totalRooms
        self.searchedBackTo = searchedBackTo
        self.statistics = statistics
    }

    public var isComplete: Bool { totalRooms > 0 && completeRooms >= totalRooms }
}
