import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// One media item in the preset Global Media Gallery entry, annotated with its source room (D34, D83).
public struct GlobalMediaItem: Sendable, Equatable, Identifiable {
    public let roomID: RoomID
    public let roomName: String
    public let item: RoomMediaItem

    public var id: String { "\(roomID.rawValue)/\(item.eventID.rawValue)" }

    public init(roomID: RoomID, roomName: String, item: RoomMediaItem) {
        self.roomID = roomID
        self.roomName = roomName
        self.item = item
    }
}

/// Media type filter inside the Global Media Gallery (D34, D83).
public enum GlobalMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case files = "Files & Audio"

    public var id: String { rawValue }
}

/// A calendar-month group of media items in the Global Media Gallery.
public struct GlobalMediaSection: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [GlobalMediaItem]

    public init(id: String, title: String, items: [GlobalMediaItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// Aggregates and organizes media across joined rooms for the preset non-Matrix Global Media Gallery entry (D34, D83).
@MainActor @Observable
public final class GlobalMediaGalleryViewModel: Identifiable {
    public let id = UUID()

    public private(set) var items: [GlobalMediaItem] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var hasMore = false
    public private(set) var error: String?
    public var filter: GlobalMediaFilter = .all
    /// When non-nil, narrows the gallery to items from a single room.
    public var selectedRoomID: RoomID?
    /// Case-insensitive search query matching filename/caption, sender name, or room name.
    public var searchText = ""

    private struct ActiveRoomSession {
        let roomID: RoomID
        let roomName: String
        let session: any RoomMediaGallerySession
    }

    private let rooms: RoomListCoordinator
    private let roomPort: any RoomPort
    private let media: MediaLoader?
    private let calendar: Calendar
    private var activeSessions: [ActiveRoomSession] = []
    private var remainingRooms: [(id: RoomID, name: String)] = []
    private var perRoomPageSize = 20
    private var roomBatchSize = 15

    public init(
        rooms: RoomListCoordinator,
        roomPort: any RoomPort,
        media: MediaLoader? = nil,
        calendar: Calendar = .current
    ) {
        self.rooms = rooms
        self.roomPort = roomPort
        self.media = media
        self.calendar = calendar
    }

    /// Distinct rooms represented in the loaded media items, sorted alphabetically by display name.
    public var availableRooms: [(id: RoomID, name: String)] {
        var seen: [RoomID: String] = [:]
        for entry in items where seen[entry.roomID] == nil {
            seen[entry.roomID] = entry.roomName
        }
        return seen
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Items matching the active media-type filter, optional room filter, and search query.
    public var filteredItems: [GlobalMediaItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { entry in
            if let selectedRoomID, entry.roomID != selectedRoomID { return false }
            if !needle.isEmpty {
                let matchesBody = entry.item.attachment.body.localizedCaseInsensitiveContains(needle)
                let matchesRoom = entry.roomName.localizedCaseInsensitiveContains(needle)
                let matchesSender = entry.item.senderName.localizedCaseInsensitiveContains(needle)
                if !matchesBody && !matchesRoom && !matchesSender { return false }
            }
            switch filter {
            case .all:
                return true
            case .photos:
                return entry.item.attachment.kind == .image
            case .videos:
                return entry.item.attachment.kind == .video
            case .files:
                return entry.item.attachment.kind == .file || entry.item.attachment.kind == .audio
            }
        }
    }

    /// Filtered items grouped by calendar month (newest month first).
    public var sections: [GlobalMediaSection] {
        let filtered = filteredItems
        guard !filtered.isEmpty else { return [] }

        var buckets: [(key: String, title: String, items: [GlobalMediaItem])] = []
        var indexByKey: [String: Int] = [:]

        for entry in filtered {
            let comps = calendar.dateComponents([.year, .month], from: entry.item.timestamp)
            let year = comps.year ?? 0
            let month = comps.month ?? 0
            let key = String(format: "%04d-%02d", year, month)
            if let idx = indexByKey[key] {
                buckets[idx].items.append(entry)
            } else {
                let title = Self.monthTitle(for: entry.item.timestamp, calendar: calendar)
                indexByKey[key] = buckets.count
                buckets.append((key: key, title: title, items: [entry]))
            }
        }
        return buckets.map { GlobalMediaSection(id: $0.key, title: $0.title, items: $0.items) }
    }

    /// Loads the first page of media across joined rooms with bounded concurrency (max 4 rooms in flight, paged in M19-5).
    public func load(perRoomLimit: Int = 20, maxRooms: Int = 15) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        perRoomPageSize = perRoomLimit
        roomBatchSize = maxRooms
        defer { isLoading = false }

        await closeSessions()
        let joined = (await rooms.rooms)
            .filter { $0.membership == .joined }
            .map { (id: $0.id, name: $0.name ?? $0.id.rawValue) }
        guard !joined.isEmpty else {
            items = []
            selectedRoomID = nil
            hasMore = false
            return
        }

        let batch = Array(joined.prefix(maxRooms))
        remainingRooms = Array(joined.dropFirst(maxRooms))

        let outcome = await openAndFetchFirstPage(for: batch, limit: perRoomLimit)
        activeSessions = outcome.continuingSessions
        items = Self.mergedAndSorted(existing: [], incoming: outcome.items)
        hasMore = !activeSessions.isEmpty || !remainingRooms.isEmpty

        if let selectedRoomID, !items.contains(where: { $0.roomID == selectedRoomID }) {
            self.selectedRoomID = nil
        }
        if !outcome.succeededAny, let firstError = outcome.firstError {
            error = Self.text(firstError)
        }
    }

    /// Loads the next page of media from active rooms and opens the next batch of rooms if any remain (M19-5).
    public func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let currentSessions = activeSessions
        activeSessions = []
        let nextRooms = Array(remainingRooms.prefix(roomBatchSize))
        remainingRooms = Array(remainingRooms.dropFirst(nextRooms.count))

        var collected: [GlobalMediaItem] = []
        var continuing: [ActiveRoomSession] = []

        if !currentSessions.isEmpty {
            let pageLimit = perRoomPageSize
            let maxConcurrency = 4
            typealias PageResult = (session: ActiveRoomSession, result: Result<MediaGalleryPage, HaloError>)
            await withTaskGroup(of: PageResult.self) { group in
                var index = 0
                func enqueue() {
                    guard index < currentSessions.count else { return }
                    let entry = currentSessions[index]
                    index += 1
                    group.addTask {
                        do throws(HaloError) {
                            let page = try await entry.session.nextPage(limit: pageLimit)
                            return (entry, .success(page))
                        } catch {
                            return (entry, .failure(error))
                        }
                    }
                }
                for _ in 0..<min(maxConcurrency, currentSessions.count) { enqueue() }
                for await outcome in group {
                    switch outcome.result {
                    case .success(let page):
                        collected.append(contentsOf: page.items.map {
                            GlobalMediaItem(roomID: outcome.session.roomID, roomName: outcome.session.roomName, item: $0)
                        })
                        if page.hasMore {
                            continuing.append(outcome.session)
                        } else {
                            await outcome.session.session.close()
                        }
                    case .failure:
                        await outcome.session.session.close()
                    }
                    enqueue()
                }
            }
        }

        if !nextRooms.isEmpty {
            let opened = await openAndFetchFirstPage(for: nextRooms, limit: perRoomPageSize)
            collected.append(contentsOf: opened.items)
            continuing.append(contentsOf: opened.continuingSessions)
        }

        activeSessions = continuing
        items = Self.mergedAndSorted(existing: items, incoming: collected)
        hasMore = !activeSessions.isEmpty || !remainingRooms.isEmpty
    }

    /// Releases all open room gallery timeline sessions when the screen disappears (AGENTS §8).
    public func closeSessions() async {
        let toClose = activeSessions
        activeSessions = []
        remainingRooms = []
        for entry in toClose {
            await entry.session.close()
        }
    }

    private struct BatchOutcome {
        var items: [GlobalMediaItem] = []
        var continuingSessions: [ActiveRoomSession] = []
        var firstError: HaloError?
        var succeededAny = false
    }

    private func openAndFetchFirstPage(for batch: [(id: RoomID, name: String)], limit: Int) async -> BatchOutcome {
        let port = roomPort
        let maxConcurrency = 4
        var outcome = BatchOutcome()

        typealias RoomResult = (roomID: RoomID, roomName: String, result: Result<(any RoomMediaGallerySession, MediaGalleryPage), HaloError>)
        await withTaskGroup(of: RoomResult.self) { group in
            var nextIndex = 0
            func enqueue() {
                guard nextIndex < batch.count else { return }
                let room = batch[nextIndex]
                nextIndex += 1
                group.addTask {
                    do throws(HaloError) {
                        let session = try await port.openMediaGallery(in: room.id)
                        do throws(HaloError) {
                            let page = try await session.nextPage(limit: limit)
                            return (room.id, room.name, .success((session, page)))
                        } catch {
                            await session.close()
                            return (room.id, room.name, .failure(error))
                        }
                    } catch {
                        return (room.id, room.name, .failure(error))
                    }
                }
            }

            for _ in 0..<min(maxConcurrency, batch.count) { enqueue() }
            for await entry in group {
                switch entry.result {
                case .success(let (session, page)):
                    outcome.succeededAny = true
                    outcome.items.append(contentsOf: page.items.map {
                        GlobalMediaItem(roomID: entry.roomID, roomName: entry.roomName, item: $0)
                    })
                    if page.hasMore {
                        outcome.continuingSessions.append(ActiveRoomSession(roomID: entry.roomID, roomName: entry.roomName, session: session))
                    } else {
                        await session.close()
                    }
                case .failure(let err):
                    if outcome.firstError == nil { outcome.firstError = err }
                }
                enqueue()
            }
        }
        return outcome
    }

    private static func mergedAndSorted(existing: [GlobalMediaItem], incoming: [GlobalMediaItem]) -> [GlobalMediaItem] {
        var seen = Set(existing.map(\.id))
        var combined = existing
        for entry in incoming where seen.insert(entry.id).inserted {
            combined.append(entry)
        }
        combined.sort { lhs, rhs in
            if lhs.item.timestamp != rhs.item.timestamp {
                return lhs.item.timestamp > rhs.item.timestamp
            }
            return lhs.id < rhs.id
        }
        return combined
    }

    public func thumbnailData(_ ref: MediaRef, size: Int = 240) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(ref, width: size, height: size)  // best-effort: a picture that can't load shows its placeholder; nothing changes
    }

    /// Loads a gallery grid thumbnail, preferring a precomputed thumbnail via the SDK file cache (M19-5).
    public func thumbnailData(for attachment: MediaAttachment, size: Int = 400) async -> Data? {
        guard let media else { return nil }
        if let thumb = attachment.thumbnail, let direct = try? await media.cachedContent(thumb) {  // best-effort: falls back to server thumbnail
            return direct
        }
        guard attachment.kind == .image, let source = attachment.source else { return nil }
        return try? await media.thumbnail(source, width: size, height: size)  // best-effort: a picture that can't load shows its placeholder; nothing changes
    }

    /// Streams a gallery photo to a temporary file on disk for the full-screen viewer (M19-5), falling back to a thumbnail.
    public func fullImageFile(_ entry: GlobalMediaItem) async -> URL? {
        guard let media, let source = entry.item.attachment.source else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-viewer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = Self.safeMediaFilename(entry.item.attachment.body, defaultName: "photo.jpg")
            if let url = try? await media.file(source, name: safeName, mimeType: entry.item.attachment.mimeType, in: dir) {  // best-effort: falls back to thumbnail preview
                return url
            }
            if let thumb = try? await media.thumbnail(source, width: 1200, height: 1200) {  // best-effort: viewer shows placeholder when preview fails
                let url = dir.appendingPathComponent(safeName)
                try thumb.write(to: url, options: .atomic)
                return url
            }
            try? FileManager.default.removeItem(at: dir)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// Streams a gallery item straight to a temporary file on disk so the user can share/export it without holding it in RAM (M19-5).
    public func exportMediaFile(_ entry: GlobalMediaItem) async -> URL? {
        guard let media, let source = entry.item.attachment.source else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-global-gallery-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = Self.safeMediaFilename(entry.item.attachment.body, defaultName: "media")
            return try await media.file(source, name: safeName, mimeType: entry.item.attachment.mimeType, in: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    private static func safeMediaFilename(_ body: String, defaultName: String) -> String {
        let raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = (raw.isEmpty ? defaultName : raw)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? defaultName : cleaned
    }

    private static func monthTitle(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private static func text(_ error: HaloError) -> String {
        switch error {
        case .network: "No internet connection."
        case .forbidden: "You don't have permission to view media in these rooms."
        case .notFound: "Media could not be found."
        default: "Couldn't load media gallery (\(error.code))."
        }
    }
}
