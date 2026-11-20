import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `StickerPrefsPort` over the account data `one.mbm.halo.sticker_prefs` (D51).
public final class MatrixStickerPrefsPort: StickerPrefsPort {
    static let eventType = "one.mbm.halo.sticker_prefs"
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func load() async throws(HaloError) -> StickerPrefs? {
        let client = try await session.signedInClient()
        do {
            guard let json = try await client.accountData(eventType: Self.eventType) else { return nil }
            return StickerPrefs.fromAccountData(Data(json.utf8))
        } catch { throw ErrorMapper.map(error) }
    }

    public func save(_ prefs: StickerPrefs) async throws(HaloError) {
        let client = try await session.signedInClient()
        do {
            // Never overwrite data this version can't read (a newer Halo wrote it).
            if let existing = try await client.accountData(eventType: Self.eventType), StickerPrefs.fromAccountData(Data(existing.utf8)) == nil,
               (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) != nil {
                throw HaloError.unsupported("STICKER_PREFS_NEWER_VERSION")
            }
            try await client.setAccountData(eventType: Self.eventType, content: String(decoding: prefs.accountData(), as: UTF8.self))
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }
}

/// `StickerPackPort` reading `m.room.image_pack` state through `Room.stateEvents` (STICKERS §9, option A of V-ST-1).
/// [UNVERIFIED] The SDK may not store this state type for rooms synced with sliding sync; if so the result is simply
/// empty. Check against `infra/dev` before relying on it; option B (the state HTTP endpoint) would replace this class
/// behind the same port.
public final class MatrixStickerPackPort: StickerPackPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func packs(currentRoom: RoomID?) async throws(HaloError) -> StickerPackLoad {
        let client = try await session.signedInClient()
        var packs: [StickerPack] = []
        var seen: Set<PackRef> = []
        var failed = 0

        func read(_ roomID: RoomID, only key: String?, source: PackSource) async {
            do {
                let room = try await session.room(roomID)
                for event in try await room.stateEvents(eventType: .roomImagePack) where key == nil || event.stateKey == key {
                    let ref = PackRef(room: roomID, stateKey: event.stateKey)
                    guard !seen.contains(ref), let pack = ImagePackParser.parse(Data(event.contentJson.utf8), ref: ref, source: source) else { continue }
                    seen.insert(ref)
                    packs.append(pack.mapStickers { sticker in
                        sticker.with(image: (try? MediaSource.fromUrl(url: sticker.url)).map(TimelineMapper.ref))
                    })
                }
            } catch { failed += 1 }
        }

        // 1. The packs the user enabled: `{ rooms: { roomId: { stateKey: {} } } }`.
        do {
            if let json = try await client.accountData(eventType: "m.image_pack.rooms"),
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let rooms = object["rooms"] as? [String: Any] {
                for roomKey in rooms.keys.sorted() {
                    guard let roomID = try? RoomID(roomKey) else { continue }
                    let keys = (rooms[roomKey] as? [String: Any])?.keys.sorted() ?? []
                    for key in keys { await read(roomID, only: key, source: .userEnabled) }
                }
            }
        } catch { failed += 1 }
        // 2. The current room's own packs.
        if let currentRoom { await read(currentRoom, only: nil, source: .room) }
        return StickerPackLoad(packs: packs, failedSources: failed)
    }
}
