import HaloFoundation

/// Where sticker packs come from (STICKERS §9: the state-loading problem V-ST-1 is the implementation's business).
public protocol StickerPackPort: Sendable {
    /// The packs the user can use now, in spec order: those enabled in `m.image_pack.rooms`, then `currentRoom`'s own
    /// packs, then legacy ones. Packs that can't be read are left out; `StickerPackLoad.failedSources` says how many.
    func packs(currentRoom: RoomID?) async throws(HaloError) -> StickerPackLoad
}

public struct StickerPackLoad: Sendable, Equatable {
    public let packs: [StickerPack]
    /// How many sources (rooms, account data) couldn't be read, so the panel can say it is incomplete.
    public let failedSources: Int

    public init(packs: [StickerPack], failedSources: Int = 0) {
        self.packs = packs
        self.failedSources = failedSources
    }
}

/// The account data `one.mbm.halo.sticker_prefs` (D51).
public protocol StickerPrefsPort: Sendable {
    /// The stored prefs; `nil` if there are none, or if the stored data is from a newer version and must be left alone.
    func load() async throws(HaloError) -> StickerPrefs?

    /// Writes `prefs` as the account data.
    func save(_ prefs: StickerPrefs) async throws(HaloError)
}
