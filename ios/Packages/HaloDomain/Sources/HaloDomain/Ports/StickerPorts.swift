import HaloFoundation

/// Where sticker packs come from (STICKERS §9: the state-loading problem V-ST-1 is the implementation's business).
public protocol StickerPackPort: Sendable {
    /// The packs the user can use now, in spec order: those enabled in `m.image_pack.rooms`, then `currentRoom`'s own
    /// packs, then legacy ones. Packs that can't be read are left out; `StickerPackLoad.failedSources` says how many.
    func packs(currentRoom: RoomID?) async throws(HaloError) -> StickerPackLoad

    /// Takes `ref` out of the user's enabled packs (`m.image_pack.rooms`), e.g. one whose room is gone. Nothing happens when
    /// it isn't listed; the pack's room and its stickers are not touched.
    func disable(_ ref: PackRef) async throws(HaloError)
}

public struct StickerPackLoad: Sendable, Equatable {
    public let packs: [StickerPack]
    /// How many sources (rooms, account data) couldn't be read, so the panel can say it is incomplete.
    public let failedSources: Int
    /// Packs the user enabled whose room is gone, not joined any more, or no longer holds the pack (403/404): not a failure
    /// of the load, so they don't make it "incomplete" (STICKERS §10).
    public let unavailable: [PackRef]

    public init(packs: [StickerPack], failedSources: Int = 0, unavailable: [PackRef] = []) {
        self.packs = packs
        self.failedSources = failedSources
        self.unavailable = unavailable
    }
}

/// The account data `one.mbm.halo.sticker_prefs` (D51).
public protocol StickerPrefsPort: Sendable {
    /// The stored prefs; `nil` if there are none, or if the stored data is from a newer version and must be left alone.
    func load() async throws(HaloError) -> StickerPrefs?

    /// Writes `prefs` as the account data.
    func save(_ prefs: StickerPrefs) async throws(HaloError)
}

/// The rooms Halo created to hold sticker packs; the room list hides them (STICKERS §2, `one.mbm.halo.sticker_rooms`).
public protocol HiddenRoomsPort: Sendable {
    /// The pack rooms listed in the account data; empty when there are none or the data can't be read.
    func hiddenRooms() async -> Set<RoomID>
}
