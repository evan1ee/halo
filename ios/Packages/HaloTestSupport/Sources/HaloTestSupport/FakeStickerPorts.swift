import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `StickerPackPort`.
public final class FakeStickerPacks: StickerPackPort {
    private struct State {
        var load = StickerPackLoad(packs: [])
        var error: HaloError?
        var asked: [RoomID?] = []
    }
    private let state = Mutex(State())

    public init(_ load: StickerPackLoad = StickerPackLoad(packs: [])) { state.withLock { $0.load = load } }

    public func set(_ load: StickerPackLoad) { state.withLock { $0.load = load } }
    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }
    /// The `currentRoom` of each call.
    public var requests: [RoomID?] { state.withLock { $0.asked } }

    public func packs(currentRoom: RoomID?) async throws(HaloError) -> StickerPackLoad {
        let (load, error) = state.withLock { state -> (StickerPackLoad, HaloError?) in
            state.asked.append(currentRoom)
            return (state.load, state.error)
        }
        if let error { throw error }
        return load
    }
}

/// In-memory `StickerPrefsPort`; counts writes.
public final class FakeStickerPrefs: StickerPrefsPort {
    private struct State {
        var prefs: StickerPrefs?
        var saves: [StickerPrefs] = []
        var failing = false
    }
    private let state = Mutex(State())

    public init(_ prefs: StickerPrefs? = nil) { state.withLock { $0.prefs = prefs } }

    public var saves: [StickerPrefs] { state.withLock { $0.saves } }
    public var stored: StickerPrefs? { state.withLock { $0.prefs } }
    public func setFailing(_ value: Bool) { state.withLock { $0.failing = value } }
    /// Another device wrote new prefs.
    public func setRemote(_ prefs: StickerPrefs?) { state.withLock { $0.prefs = prefs } }

    public func load() async throws(HaloError) -> StickerPrefs? {
        let (failing, prefs) = state.withLock { ($0.failing, $0.prefs) }
        if failing { throw .network(retryable: true) }
        return prefs
    }

    public func save(_ prefs: StickerPrefs) async throws(HaloError) {
        if state.withLock({ $0.failing }) { throw .network(retryable: true) }
        state.withLock { $0.prefs = prefs; $0.saves.append(prefs) }
    }
}
