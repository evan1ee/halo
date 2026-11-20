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

/// `HiddenRoomsPort` over the account data `one.mbm.halo.sticker_rooms` (served from the SDK's store, which sync keeps current).
public final class MatrixHiddenRoomsPort: HiddenRoomsPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func hiddenRooms() async -> Set<RoomID> {
        guard let client = try? await session.signedInClient(),
              let json = try? await client.accountData(eventType: "one.mbm.halo.sticker_rooms"),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        return PackRegistry.packRooms(in: object)
    }
}

/// `StickerPackPort` reading `m.room.image_pack` state over the Client-Server API (STICKERS §9, option B of V-ST-1).
/// [VERIFIED against infra/dev] `Room.stateEvents(.roomImagePack)` returns nothing for this custom state type (option A), so
/// the state is read with a plain authenticated GET. This is the only direct HTTP call of the app besides discovery.
/// The access token is never logged. On a 401 the SDK is asked to refresh by making one of its own authenticated requests,
/// then the call is repeated once (V-ST-2).
public final class MatrixStickerPackPort: StickerPackPort {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let session: MatrixSessionPort
    private let fetch: Fetch
    private let roomPacks: RoomPackCache

    public init(
        session: MatrixSessionPort, fetch: @escaping Fetch = MatrixStickerPackPort.urlSessionFetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.fetch = fetch
        self.roomPacks = RoomPackCache(now: now)
    }

    /// No disk cache for authenticated responses (they hold room state), no cookies.
    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    public static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func packs(currentRoom: RoomID?) async throws(HaloError) -> StickerPackLoad {
        let client = try await session.signedInClient()
        var packs: [StickerPack] = []
        var seen: Set<PackRef> = []
        var failed = 0
        var unavailable: [PackRef] = []

        func add(_ pack: StickerPack?) {
            guard let pack, !seen.contains(pack.ref) else { return }
            seen.insert(pack.ref)
            packs.append(pack.mapStickers { sticker in
                sticker.with(image: (try? MediaSource.fromUrl(url: sticker.url)).map(TimelineMapper.ref))
            })
        }

        // 1. The packs the user enabled: `{ rooms: { roomId: { stateKey: {} } } }`.
        // 3. (read last, listed here with step 1 because both come from account data) the legacy `im.ponies.emote_rooms`
        //    listing, whose packs are `im.ponies.room_emotes` state: read-only, and only added when not already found.
        func listed(_ accountDataType: String) async -> [PackRef] {
            do {
                guard let json = try await client.accountData(eventType: accountDataType),
                      let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
                return PackRegistry.listedPacks(in: object)
            } catch { failed += 1; return [] }
        }
        for ref in await listed("m.image_pack.rooms") {
            do {
                if let content = try await stateContent(client, room: ref.room, key: ref.stateKey) { add(ImagePackParser.parse(content, ref: ref, source: .userEnabled)) }
                else { unavailable.append(ref) }  // 404: the room or the pack event is gone
            } catch is Forbidden { unavailable.append(ref)  // 403: the user is no longer in that room
            } catch { failed += 1 }
        }

        // 2. The packs of the current room, cached for a while: listing them means downloading the room's state.
        if let currentRoom {
            do {
                for pack in try await packsOfRoom(client, currentRoom) { add(pack) }
            } catch { failed += 1 }
        }
        // 3. Legacy packs (V-ST-3), after the others so that a pack found in the current format wins.
        for ref in await listed("im.ponies.emote_rooms") where !seen.contains(ref) {
            do {
                if let content = try await stateContent(client, room: ref.room, key: ref.stateKey, type: Self.legacyType) { add(ImagePackParser.parse(content, ref: ref, source: .legacy)) }
            } catch {
                // Old listings often name rooms the user has since left (403): that is an unavailable pack, not a failed source.
            }
        }
        return StickerPackLoad(packs: packs, failedSources: failed, unavailable: unavailable)
    }

    public func disable(_ ref: PackRef) async throws(HaloError) {
        let client = try await session.signedInClient()
        do {
            // Read-modify-write of the account data; unknown properties stay (PackRegistry keeps them).
            let current = try await client.accountData(eventType: "m.image_pack.rooms").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            guard let updated = PackRegistry.disabling(ref, in: current) else { return }
            try await client.setAccountData(eventType: "m.image_pack.rooms", content: String(decoding: try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]), as: UTF8.self))
        } catch { throw ErrorMapper.map(error) }
    }

    private static let legacyType = "im.ponies.room_emotes"

    /// The current room's packs. A small room's whole state is read (every state key); a large room's state can be
    /// many megabytes, so there only the pack with the empty state key is read. Results are kept for
    /// `RoomPackCache.lifetime`; failures are not kept.
    private func packsOfRoom(_ client: Client, _ room: RoomID) async throws -> [StickerPack] {
        if let cached = await roomPacks.packs(of: room) { return cached }
        // The panel is opened from a room's timeline, so the room is known locally; if it isn't, its size is unknown and
        // the whole state is read as before.
        let members = (try? await session.room(room))?.joinedMembersCount()
        var packs: [StickerPack] = []
        if members.map(StickerRoomState.readsWholeState) ?? true {
            for (key, content, legacy) in try await allPacks(client, room: room) {
                let ref = PackRef(room: room, stateKey: key)
                // A pack in the current format wins over a legacy pack with the same key.
                if legacy, packs.contains(where: { $0.ref == ref }) { continue }
                if let pack = ImagePackParser.parse(content, ref: ref, source: legacy ? .legacy : .room) { packs.append(pack) }
            }
        } else if let content = try await stateContent(client, room: room, key: "") {
            if let pack = ImagePackParser.parse(content, ref: PackRef(room: room, stateKey: ""), source: .room) { packs.append(pack) }
        }
        await roomPacks.store(packs, for: room)
        return packs
    }

    // MARK: HTTP

    private func stateContent(_ client: Client, room: RoomID, key: String, type: String = "m.room.image_pack") async throws -> [String: Any]? {
        let path = "rooms/\(Self.escape(room.rawValue))/state/\(type)/\(Self.escape(key))"
        guard let data = try await get(client, path) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// `(state key, content, isLegacy)` of the room's pack events; current-format packs come first.
    private func allPacks(_ client: Client, room: RoomID) async throws -> [(String, [String: Any], Bool)] {
        guard let data = try await get(client, "rooms/\(Self.escape(room.rawValue))/state"),
              let events = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let found: [(String, [String: Any], Bool)] = events.compactMap { event in
            guard let type = event["type"] as? String, type == "m.room.image_pack" || type == Self.legacyType,
                  let key = event["state_key"] as? String, let content = event["content"] as? [String: Any] else { return nil }
            return (key, content, type == Self.legacyType)
        }
        return found.filter { !$0.2 } + found.filter { $0.2 }
    }

    /// The response body, `nil` for 404 (no such state), an error for anything else that isn't 200.
    private func get(_ client: Client, _ path: String, retried: Bool = false) async throws -> Data? {
        let sdkSession = try client.session()
        guard var components = URLComponents(string: sdkSession.homeserverUrl) else { throw URLError(.badURL) }
        components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? "/_matrix/client/v3/\(path)" : components.percentEncodedPath + "/_matrix/client/v3/\(path)"
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(sdkSession.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await fetch(request)
        switch response.statusCode {
        case 200: return data
        case 404: return nil
        case 401 where !retried:
            _ = try? await client.accountData(eventType: "m.direct")  // an SDK request refreshes an expired token
            return try await get(client, path, retried: true)
        case 403: throw Forbidden()
        default: throw URLError(.badServerResponse)
        }
    }

    private struct Forbidden: Error {}

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? component
    }
}

/// When the sticker panel reads a room's whole state to find its packs (STICKERS §9). Pure.
enum StickerRoomState {
    /// Rooms up to this many joined members have a small enough state (roughly 1 kB per member) to read whole.
    static let wholeStateMemberLimit: UInt64 = 1_000

    static func readsWholeState(joinedMembers: UInt64) -> Bool { joinedMembers <= wholeStateMemberLimit }
}

/// The packs found in each room, kept for `lifetime` so that opening the panel again doesn't download the state again.
actor RoomPackCache {
    static let lifetime: TimeInterval = 10 * 60

    private let now: @Sendable () -> Date
    private var entries: [RoomID: (fetched: Date, packs: [StickerPack])] = [:]

    init(now: @escaping @Sendable () -> Date) { self.now = now }

    func packs(of room: RoomID) -> [StickerPack]? {
        guard let entry = entries[room] else { return nil }
        guard now().timeIntervalSince(entry.fetched) < Self.lifetime else { entries[room] = nil; return nil }
        return entry.packs
    }

    func store(_ packs: [StickerPack], for room: RoomID) { entries[room] = (now(), packs) }
}

/// `StickerPackCreationPort`: uploads the images, creates an unencrypted private room, writes the pack state, and lists the
/// room in the user's account data (STICKERS FR-7, D48). Packs and their media are not encrypted (spec).
public final class MatrixStickerPackCreationPort: StickerPackCreationPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func createPack(name: String, images: [NewStickerImage], progress: @escaping @Sendable (Int, Int) -> Void) async throws(HaloError) -> PackRef {
        try ImagePackBuilder.validate(name: name, shortcodes: images.map(\.shortcode))
        for image in images where !image.mimeType.hasPrefix("image/") { throw .invalidInput("NOT_AN_IMAGE") }
        let client = try await session.signedInClient()
        do {
            var uploaded: [(image: NewStickerImage, url: String)] = []
            for image in images {
                let url = try await client.uploadMedia(mimeType: image.mimeType, data: image.data, progressWatcher: nil)
                uploaded.append((image, url))
                progress(uploaded.count, images.count)
            }
            let roomID = try await client.createRoom(request: CreateRoomParameters(
                name: ImagePackBuilder.roomName(for: name), isEncrypted: false, visibility: .private, preset: .privateChat))
            let ref = PackRef(room: try RoomID(roomID), stateKey: ImagePackBuilder.stateKey)

            // From here on a failure would leave an empty "Sticker pack" room in the room list, and trying again would make
            // another one: the room is left and forgotten before the error is passed on.
            var room: Room?
            do {
                // The room must be known locally before a state event can be sent into it.
                for _ in 0..<30 {
                    if let known = try? await session.room(ref.room) { room = known; break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard let room else { throw HaloError.notFound }
                let content = ImagePackBuilder.content(name: name, uploaded: uploaded)
                _ = try await room.sendStateEventRaw(
                    eventType: "m.room.image_pack", stateKey: ref.stateKey,
                    content: String(decoding: try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), as: UTF8.self), requestConfigOverride: nil)

                try await update(client, "m.image_pack.rooms") { PackRegistry.enabling(ref, in: $0) }
                try await update(client, "one.mbm.halo.sticker_rooms") { PackRegistry.recordingPackRoom(ref.room, in: $0) }
                return ref
            } catch {
                var known = room
                if known == nil { known = try? await session.room(ref.room) }
                await abandon(known, registeredAs: ref, client: client)
                throw error
            }
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    /// Best effort, after a failed creation: removes the pack from the enabled list in case that write got through, then
    /// leaves and forgets the room. The uploaded media stay on the server (there is no API to delete them).
    private func abandon(_ room: Room?, registeredAs ref: PackRef, client: Client) async {
        try? await update(client, "m.image_pack.rooms") { PackRegistry.disabling(ref, in: $0) }
        guard let room else { return }
        try? await room.leave()
        try? await room.forget()
    }

    /// Read-modify-write of account data; `nil` from `change` leaves it alone.
    private func update(_ client: Client, _ type: String, _ change: ([String: Any]?) -> [String: Any]?) async throws {
        let current = try await client.accountData(eventType: type).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard let updated = change(current) else { return }
        try await client.setAccountData(eventType: type, content: String(decoding: try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]), as: UTF8.self))
    }
}
