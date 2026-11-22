import HaloDomain
import HaloFoundation
import Synchronization

/// In-memory `StickerPackPort`.
public final class FakeStickerPacks: StickerPackPort {
    private struct State {
        var load = StickerPackLoad(packs: [])
        var error: HaloError?
        var asked: [RoomID?] = []
        var disabled: [PackRef] = []
    }
    private let state = Mutex(State())

    public init(_ load: StickerPackLoad = StickerPackLoad(packs: [])) { state.withLock { $0.load = load } }

    public func set(_ load: StickerPackLoad) { state.withLock { $0.load = load } }
    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }
    /// The `currentRoom` of each call.
    public var requests: [RoomID?] { state.withLock { $0.asked } }
    /// The packs `disable` was called with.
    public var disabled: [PackRef] { state.withLock { $0.disabled } }

    public func disable(_ ref: PackRef) async throws(HaloError) { state.withLock { $0.disabled.append(ref) } }

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

/// In-memory `StickerPackCreationPort`; records what it was asked to create.
public final class FakeStickerPackCreation: StickerPackCreationPort {
    public struct Created: Sendable, Equatable {
        public let name: String
        public let images: [NewStickerImage]
    }
    private struct State {
        var created: [Created] = []
        var error: HaloError?
    }
    private let state = Mutex(State())

    public init() {}

    public var created: [Created] { state.withLock { $0.created } }
    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }

    public func createPack(name: String, images: [NewStickerImage], progress: @escaping @Sendable (Int, Int) -> Void) async throws(HaloError) -> PackRef {
        try ImagePackBuilder.validate(name: name, shortcodes: images.map(\.shortcode))
        if let error = state.withLock({ $0.error }) { throw error }
        for index in images.indices { progress(index + 1, images.count) }
        state.withLock { $0.created.append(Created(name: name, images: images)) }
        guard let room = try? RoomID("!pack\(state.withLock { $0.created.count }):x.org") else { throw .internal(code: "FAKE_ROOM_ID") }
        return PackRef(room: room, stateKey: ImagePackBuilder.stateKey)
    }
}
