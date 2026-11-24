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

/// In-memory `StickerPackManagementPort`; records mutations and optionally updates a backing `FakeStickerPacks`.
public final class FakeStickerPackManagement: StickerPackManagementPort {
    public struct Renamed: Sendable, Equatable {
        public let ref: PackRef
        public let name: String
    }
    public struct Added: Sendable, Equatable {
        public let ref: PackRef
        public let images: [NewStickerImage]
    }
    public struct RemovedSticker: Sendable, Equatable {
        public let ref: PackRef
        public let shortcode: String
    }

    private struct State {
        var renamed: [Renamed] = []
        var added: [Added] = []
        var removedStickers: [RemovedSticker] = []
        var deletedPacks: [PackRef] = []
        var error: HaloError?
    }
    private let state = Mutex(State())
    private let backing: FakeStickerPacks?

    public init(backing: FakeStickerPacks? = nil) { self.backing = backing }

    public var renamed: [Renamed] { state.withLock { $0.renamed } }
    public var added: [Added] { state.withLock { $0.added } }
    public var removedStickers: [RemovedSticker] { state.withLock { $0.removedStickers } }
    public var deletedPacks: [PackRef] { state.withLock { $0.deletedPacks } }
    public func fail(with error: HaloError?) { state.withLock { $0.error = error } }

    public func renamePack(_ ref: PackRef, to name: String) async throws(HaloError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("EMPTY_PACK_NAME") }
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.renamed.append(Renamed(ref: ref, name: trimmed)) }
        if let backing {
            let current = try await backing.packs(currentRoom: nil)
            let updated = current.packs.map { pack in
                pack.ref == ref
                    ? StickerPack(ref: pack.ref, displayName: trimmed, avatarURL: pack.avatarURL, usage: pack.usage, attribution: pack.attribution, stickers: pack.stickers, source: pack.source)
                    : pack
            }
            backing.set(StickerPackLoad(packs: updated, failedSources: current.failedSources, unavailable: current.unavailable))
        }
    }

    public func addStickers(_ images: [NewStickerImage], to ref: PackRef, progress: @escaping @Sendable (Int, Int) -> Void) async throws(HaloError) {
        guard !images.isEmpty else { throw .invalidInput("NO_IMAGES") }
        if let error = state.withLock({ $0.error }) { throw error }
        for index in images.indices { progress(index + 1, images.count) }
        state.withLock { $0.added.append(Added(ref: ref, images: images)) }
        if let backing {
            let current = try await backing.packs(currentRoom: nil)
            let updated = current.packs.map { pack in
                guard pack.ref == ref else { return pack }
                let newStickers = images.map {
                    Sticker(pack: ref, shortcode: $0.shortcode, body: $0.body, url: "mxc://fake/\($0.shortcode)", info: StickerInfo(width: $0.width, height: $0.height, mimeType: $0.mimeType, size: $0.data.count))
                }
                return StickerPack(ref: pack.ref, displayName: pack.displayName, avatarURL: pack.avatarURL, usage: pack.usage, attribution: pack.attribution, stickers: pack.stickers + newStickers, source: pack.source)
            }
            backing.set(StickerPackLoad(packs: updated, failedSources: current.failedSources, unavailable: current.unavailable))
        }
    }

    public func removeSticker(shortcode: String, from ref: PackRef) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.removedStickers.append(RemovedSticker(ref: ref, shortcode: shortcode)) }
        if let backing {
            let current = try await backing.packs(currentRoom: nil)
            let updated = current.packs.map { pack in
                guard pack.ref == ref else { return pack }
                return StickerPack(ref: pack.ref, displayName: pack.displayName, avatarURL: pack.avatarURL, usage: pack.usage, attribution: pack.attribution, stickers: pack.stickers.filter { $0.shortcode != shortcode }, source: pack.source)
            }
            backing.set(StickerPackLoad(packs: updated, failedSources: current.failedSources, unavailable: current.unavailable))
        }
    }

    public func deletePack(_ ref: PackRef) async throws(HaloError) {
        if let error = state.withLock({ $0.error }) { throw error }
        state.withLock { $0.deletedPacks.append(ref) }
        if let backing {
            let current = try await backing.packs(currentRoom: nil)
            backing.set(StickerPackLoad(packs: current.packs.filter { $0.ref != ref }, failedSources: current.failedSources, unavailable: current.unavailable))
        }
    }
}
