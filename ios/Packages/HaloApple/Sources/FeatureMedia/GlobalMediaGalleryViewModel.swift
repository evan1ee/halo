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
    public private(set) var error: String?
    public var filter: GlobalMediaFilter = .all
    /// When non-nil, narrows the gallery to items from a single room.
    public var selectedRoomID: RoomID?
    /// Case-insensitive search query matching filename/caption, sender name, or room name.
    public var searchText = ""

    private let rooms: RoomListCoordinator
    private let roomPort: any RoomPort
    private let media: MediaLoader?
    private let calendar: Calendar

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

    /// Loads recent media across joined rooms with bounded concurrency (max 4 rooms in flight).
    public func load(perRoomLimit: Int = 30, maxRooms: Int = 25) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        let joined = Array((await rooms.rooms).filter { $0.membership == .joined }.prefix(maxRooms))
        guard !joined.isEmpty else {
            items = []
            selectedRoomID = nil
            return
        }

        let port = roomPort
        let maxConcurrency = 4
        var collected: [GlobalMediaItem] = []
        var firstError: HaloError?
        var succeededAny = false

        await withTaskGroup(of: Result<[GlobalMediaItem], HaloError>.self) { group in
            var nextIndex = 0
            let initial = min(maxConcurrency, joined.count)
            for _ in 0..<initial {
                let summary = joined[nextIndex]
                let displayName = summary.name ?? summary.id.rawValue
                nextIndex += 1
                group.addTask {
                    do throws(HaloError) {
                        let roomItems = try await port.mediaGallery(in: summary.id, limit: perRoomLimit)
                        return .success(roomItems.map { GlobalMediaItem(roomID: summary.id, roomName: displayName, item: $0) })
                    } catch {
                        return .failure(error)
                    }
                }
            }

            for await result in group {
                switch result {
                case .success(let batch):
                    succeededAny = true
                    collected.append(contentsOf: batch)
                case .failure(let err):
                    if firstError == nil { firstError = err }
                }

                if nextIndex < joined.count {
                    let summary = joined[nextIndex]
                    let displayName = summary.name ?? summary.id.rawValue
                    nextIndex += 1
                    group.addTask {
                        do throws(HaloError) {
                            let roomItems = try await port.mediaGallery(in: summary.id, limit: perRoomLimit)
                            return .success(roomItems.map { GlobalMediaItem(roomID: summary.id, roomName: displayName, item: $0) })
                        } catch {
                            return .failure(error)
                        }
                    }
                }
            }
        }

        collected.sort { lhs, rhs in
            if lhs.item.timestamp != rhs.item.timestamp {
                return lhs.item.timestamp > rhs.item.timestamp
            }
            return lhs.id < rhs.id
        }

        items = collected
        if let selectedRoomID, !items.contains(where: { $0.roomID == selectedRoomID }) {
            self.selectedRoomID = nil
        }
        if !succeededAny, let firstError {
            error = Self.text(firstError)
        }
    }

    public func thumbnailData(_ ref: MediaRef, size: Int = 240) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(ref, width: size, height: size)
    }

    public func fullImageData(_ ref: MediaRef) async -> Data? {
        guard let media else { return nil }
        return try? await media.content(ref)
    }

    /// Downloads full bytes of a gallery item to a temporary file so the user can share/export it.
    public func exportMediaFile(_ entry: GlobalMediaItem) async -> URL? {
        guard let media, let source = entry.item.attachment.source else { return nil }
        do {
            let bytes = try await media.content(source)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("halo-global-gallery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let rawName = entry.item.attachment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeName = (rawName.isEmpty ? "media" : rawName)
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let url = dir.appendingPathComponent(safeName)
            try bytes.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
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
