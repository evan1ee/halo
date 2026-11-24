import Foundation
import HaloDomain
import HaloFoundation

/// The sticker panel's data (STICKERS FR-1…FR-6): packs, favourites, recents and search. Prefs are read and merged with
/// what another device wrote (last use wins, favourites union), and recents are written at most once per
/// `writeInterval`; a write that is due later is sent by a trailing task.
public actor StickerLibrary {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public enum Phase: Sendable, Equatable { case unloaded, loading, ready, partial, failed }

    /// What the panel shows.
    public struct Snapshot: Sendable, Equatable {
        public var phase: Phase = .unloaded
        /// Packs that offer stickers, in source order.
        public var packs: [StickerPack] = []
        public var favourites: [Sticker] = []
        public var recents: [Sticker] = []
        /// Favourites whose pack or image is gone; shown greyed out and removable.
        public var unavailableFavourites: [StickerRef] = []
        /// Enabled packs that can't be read (room left, forgotten or the pack deleted).
        public var unavailablePacks: [PackRef] = []

        public init(
            phase: Phase = .unloaded, packs: [StickerPack] = [], favourites: [Sticker] = [], recents: [Sticker] = [],
            unavailableFavourites: [StickerRef] = [], unavailablePacks: [PackRef] = []
        ) {
            self.unavailablePacks = unavailablePacks
            self.phase = phase
            self.packs = packs
            self.favourites = favourites
            self.recents = recents
            self.unavailableFavourites = unavailableFavourites
        }
    }

    public static let writeInterval: Duration = .seconds(10)

    private let packSource: any StickerPackPort
    private let prefsStore: any StickerPrefsPort
    private let now: @Sendable () -> Date
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let sleep: Sleep
    private var prefs = StickerPrefs()
    private var allPacks: [StickerPack] = []
    private var currentRoom: RoomID?
    private var unavailablePacks: [PackRef] = []
    private var phase = Phase.unloaded
    private var lastWrite: ContinuousClock.Instant?
    private var trailing: Task<Void, Never>?
    private var dirty = false
    /// Bumped by `reset()`; work that started for the previous account drops its results.
    private var generation = 0
    private var broadcaster = SnapshotBroadcaster<Snapshot>()

    public init(
        packs: any StickerPackPort, prefs: any StickerPrefsPort, now: @escaping @Sendable () -> Date = { Date() },
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.packSource = packs
        self.prefsStore = prefs
        self.now = now
        self.clock = clock
        self.sleep = sleep
    }

    deinit { trailing?.cancel() }

    public func snapshots() -> AsyncStream<Snapshot> { broadcaster.subscribe(current: snapshot()) }

    /// Reloads using the last requested room.
    public func reload() async { await load(currentRoom: currentRoom) }

    /// Loads packs and prefs for the panel opened in `currentRoom`. Safe to call again to refresh.
    public func load(currentRoom: RoomID?) async {
        self.currentRoom = currentRoom
        let started = generation
        phase = .loading
        publish()
        let remote = try? await prefsStore.load()
        guard generation == started else { return }
        if let remote { prefs = prefs.merged(with: remote) }
        do {
            let result = try await packSource.packs(currentRoom: currentRoom)
            guard generation == started else { return }
            allPacks = result.packs.filter(\.offersStickers)
            unavailablePacks = result.unavailable
            phase = result.failedSources > 0 ? .partial : .ready
        } catch {
            guard generation == started else { return }
            phase = allPacks.isEmpty ? .failed : .partial
        }
        publish()
    }

    /// Removes the packs that can't be read any more from the user's enabled list, then reloads. A pack that can't be removed
    /// (offline) stays listed as unavailable and shows up again on the next try.
    public func removeUnavailablePacks() async {
        let started = generation
        for ref in unavailablePacks {
            do { try await packSource.disable(ref) } catch { continue }
        }
        guard generation == started else { return }
        await load(currentRoom: currentRoom)
    }

    /// Takes one enabled pack out of the user's list (Settings → Stickers → manage packs), then reloads. Returns `false` when the
    /// server call failed, so the screen can say so; the pack then stays listed. A pack that only shows because it belongs to the
    /// current room (never enabled) is not affected by `disable` and comes back after the reload.
    @discardableResult
    public func disablePack(_ ref: PackRef) async -> Bool {
        let started = generation
        do { try await packSource.disable(ref) } catch { return false }
        guard generation == started else { return true }
        await load(currentRoom: currentRoom)
        return true
    }

    /// Forgets everything of the signed-out account, so none of it is shown to, or written into, the next one. A load or
    /// write still running for the old account drops its result. Call `flush()` first to keep a pending write.
    public func reset() {
        generation += 1
        trailing?.cancel()
        trailing = nil
        prefs = StickerPrefs()
        allPacks = []
        unavailablePacks = []
        phase = .unloaded
        lastWrite = nil
        dirty = false
        publish()
    }

    /// Search over the visible packs (FR-4).
    public func search(_ query: String) -> [Sticker] { StickerSearch.search(query, in: allPacks, prefs: prefs) }

    public func isFavourite(_ sticker: Sticker) -> Bool { prefs.isFavourite(sticker.ref) }

    /// Adds or removes a favourite and writes at once (a rare action).
    public func toggleFavourite(_ ref: StickerRef) async {
        prefs.toggleFavourite(ref)
        publish()
        await write()
    }

    /// Notes that `sticker` was sent. The write is debounced to one per `writeInterval` (FR-6).
    public func recordSent(_ sticker: Sticker) async {
        prefs.recordUse(sticker.ref, at: now())
        publish()
        dirty = true
        let wait: Duration = lastWrite.map { max(.zero, Self.writeInterval - $0.duration(to: clock())) } ?? .zero
        if wait == .zero { await write(); return }
        guard trailing == nil else { return }
        trailing = Task { [weak self, sleep] in
            do { try await sleep(wait) } catch { return }
            await self?.writeTrailing()
        }
    }

    /// Sends a pending recents write now (the panel closed, the app is going to the background).
    public func flush() async {
        trailing?.cancel()
        trailing = nil
        if dirty { await write() }
    }

    // MARK: -

    private func writeTrailing() async {
        trailing = nil
        if dirty { await write() }
    }

    /// Writes the prefs with the latest remote recents merged in, so another device's uses are not lost. Favourites are
    /// not merged here: a union could never carry a removal. (Known limit: a device with a stale list can bring a removed
    /// favourite back when it next loads and writes.)
    private func write() async {
        let started = generation
        lastWrite = clock()
        dirty = false
        do {
            let remote = try await prefsStore.load()
            guard generation == started else { return }
            if let remote { prefs = prefs.merged(with: StickerPrefs(recents: remote.recents)) }
            try await prefsStore.save(prefs)
        } catch {
            if generation == started { dirty = true }  // kept for the next write
        }
    }

    private func snapshot() -> Snapshot {
        var index: [StickerRef: Sticker] = [:]
        for pack in allPacks { for sticker in pack.stickers { index[sticker.ref] = sticker } }
        let favourites = prefs.favourites.compactMap { index[$0] }
        return Snapshot(
            phase: phase, packs: allPacks, favourites: favourites, recents: prefs.recents.compactMap { index[$0.sticker] },
            unavailableFavourites: phase == .ready ? prefs.favourites.filter { index[$0] == nil } : [],
            unavailablePacks: unavailablePacks)
    }

    private func publish() { broadcaster.publish(snapshot()) }
}
