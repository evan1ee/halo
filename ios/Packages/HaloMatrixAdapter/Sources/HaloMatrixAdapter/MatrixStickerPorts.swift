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

/// `StickerPackPort` reading `m.room.image_pack` state over the Client-Server API (STICKERS §9, option B of V-ST-1).
/// [VERIFIED against infra/dev] `Room.stateEvents(.roomImagePack)` returns nothing for this custom state type (option A), so
/// the state is read with a plain authenticated GET. This is the only direct HTTP call of the app besides discovery.
/// The access token is never logged. On a 401 the SDK is asked to refresh by making one of its own authenticated requests,
/// then the call is repeated once (V-ST-2).
public final class MatrixStickerPackPort: StickerPackPort {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let session: MatrixSessionPort
    private let fetch: Fetch

    public init(session: MatrixSessionPort, fetch: @escaping Fetch = MatrixStickerPackPort.urlSessionFetch) {
        self.session = session
        self.fetch = fetch
    }

    public static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func packs(currentRoom: RoomID?) async throws(HaloError) -> StickerPackLoad {
        let client = try await session.signedInClient()
        var packs: [StickerPack] = []
        var seen: Set<PackRef> = []
        var failed = 0

        func add(_ pack: StickerPack?) {
            guard let pack, !seen.contains(pack.ref) else { return }
            seen.insert(pack.ref)
            packs.append(pack.mapStickers { sticker in
                sticker.with(image: (try? MediaSource.fromUrl(url: sticker.url)).map(TimelineMapper.ref))
            })
        }

        // 1. The packs the user enabled: `{ rooms: { roomId: { stateKey: {} } } }`.
        do {
            if let json = try await client.accountData(eventType: "m.image_pack.rooms"),
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let rooms = object["rooms"] as? [String: Any] {
                for roomKey in rooms.keys.sorted() {
                    guard let roomID = try? RoomID(roomKey) else { continue }
                    for key in ((rooms[roomKey] as? [String: Any])?.keys.sorted() ?? []) {
                        do {
                            let ref = PackRef(room: roomID, stateKey: key)
                            if let content = try await stateContent(client, room: roomID, key: key) { add(ImagePackParser.parse(content, ref: ref, source: .userEnabled)) }
                        } catch { failed += 1 }
                    }
                }
            }
        } catch { failed += 1 }

        // 2. Every pack in the current room.
        if let currentRoom {
            do {
                for (key, content) in try await allPacks(client, room: currentRoom) {
                    add(ImagePackParser.parse(content, ref: PackRef(room: currentRoom, stateKey: key), source: .room))
                }
            } catch { failed += 1 }
        }
        return StickerPackLoad(packs: packs, failedSources: failed)
    }

    // MARK: HTTP

    private func stateContent(_ client: Client, room: RoomID, key: String) async throws -> [String: Any]? {
        let path = "rooms/\(Self.escape(room.rawValue))/state/m.room.image_pack/\(Self.escape(key))"
        guard let data = try await get(client, path) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func allPacks(_ client: Client, room: RoomID) async throws -> [(String, [String: Any])] {
        guard let data = try await get(client, "rooms/\(Self.escape(room.rawValue))/state"),
              let events = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return events.compactMap { event in
            guard event["type"] as? String == "m.room.image_pack", let key = event["state_key"] as? String, let content = event["content"] as? [String: Any] else { return nil }
            return (key, content)
        }
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
        default: throw URLError(.badServerResponse)
        }
    }

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? component
    }
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

            // The room must be known locally before a state event can be sent into it.
            var room: Room?
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
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }

    /// Read-modify-write of account data; `nil` from `change` leaves it alone.
    private func update(_ client: Client, _ type: String, _ change: ([String: Any]?) -> [String: Any]?) async throws {
        let current = try await client.accountData(eventType: type).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard let updated = change(current) else { return }
        try await client.setAccountData(eventType: type, content: String(decoding: try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]), as: UTF8.self))
    }
}
