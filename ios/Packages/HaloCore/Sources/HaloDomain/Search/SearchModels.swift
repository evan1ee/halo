import Foundation
import HaloFoundation

/// What a message is for the search filters (MESSAGE_SEARCH FR-8). Raw values are stored.
public enum SearchKind: Int, Sendable, Codable, CaseIterable {
    case message = 0
    /// A picture, video or audio file.
    case media = 1
    case file = 2
    /// A message with a web address in it.
    case link = 3
}

/// What a person searches in.
public enum SearchFilter: String, Sendable, CaseIterable, Codable {
    case all, messages, media, files, links

    public var kinds: Set<SearchKind> {
        switch self {
        case .all: Set(SearchKind.allCases)
        case .messages: [.message, .link]
        case .media: [.media]
        case .files: [.file]
        case .links: [.link]
        }
    }
}

/// Attachment details shown inside a search result card (thumbnail, format and file size).
public struct SearchAttachment: Sendable, Equatable, Codable {
    public let mediaKind: MediaKind
    public let filename: String?
    public let mimeType: String?
    public let sizeBytes: Int?
    /// Thumbnail (or image) reference for inline preview; `nil` when none is available.
    public let thumbnail: MediaRef?

    public init(
        mediaKind: MediaKind, filename: String? = nil, mimeType: String? = nil,
        sizeBytes: Int? = nil, thumbnail: MediaRef? = nil
    ) {
        self.mediaKind = mediaKind
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.thumbnail = thumbnail
    }

    private enum CodingKeys: String, CodingKey {
        case mediaKind, filename, mimeType, sizeBytes, thumbnailToken
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .mediaKind)
        mediaKind = switch rawKind {
        case "image": .image
        case "video": .video
        case "audio": .audio
        default: .file
        }
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnailToken).map(MediaRef.init(token:))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let rawKind: String = switch mediaKind {
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .file: "file"
        }
        try container.encode(rawKind, forKey: .mediaKind)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(thumbnail?.token, forKey: .thumbnailToken)
    }

    /// Compact metadata line such as `"PNG (1.4 MB)"`, `"PDF (240 KB)"`, or `"Photo"`.
    public var subtitle: String {
        let format = Self.formatLabel(mediaKind: mediaKind, mimeType: mimeType, filename: filename)
        guard let sizeBytes, sizeBytes > 0 else { return format }
        return "\(format) (\(Self.sizeLabel(sizeBytes)))"
    }

    private static func formatLabel(mediaKind: MediaKind, mimeType: String?, filename: String?) -> String {
        if let mime = mimeType?.lowercased().split(separator: ";").first.map(String.init) {
            switch mime {
            case "image/jpeg", "image/jpg": return "JPEG"
            case "image/png": return "PNG"
            case "image/webp": return "WEBP"
            case "image/gif": return "GIF"
            case "image/heic": return "HEIC"
            case "image/heif": return "HEIF"
            case "video/mp4": return "MP4"
            case "video/quicktime": return "MOV"
            case "video/webm": return "WEBM"
            case "audio/mp4", "audio/x-m4a", "audio/m4a": return "M4A"
            case "audio/mpeg", "audio/mp3": return "MP3"
            case "audio/ogg", "audio/opus": return "OGG"
            case "audio/wav", "audio/x-wav": return "WAV"
            case "application/pdf": return "PDF"
            case "application/zip": return "ZIP"
            case "text/plain": return "TXT"
            case "text/markdown": return "MD"
            default:
                if let subtype = mime.split(separator: "/").last,
                   !subtype.contains("octet-stream"),
                   subtype.count <= 6,
                   subtype.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    return subtype.uppercased()
                }
            }
        }
        if let name = filename, let dot = name.lastIndex(of: ".") {
            let ext = name[name.index(after: dot)...]
            if !ext.isEmpty, ext.count <= 6, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return ext.uppercased()
            }
        }
        return switch mediaKind {
        case .image: "Photo"
        case .video: "Video"
        case .audio: "Audio"
        case .file: "File"
        }
    }

    private static func sizeLabel(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(bytes) B" }
        if bytes < 1_000_000 {
            let kb = max(1, Int((Double(bytes) / 1_000).rounded()))
            return "\(kb) KB"
        }
        if bytes < 1_000_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        return String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
}

/// The words of one message and what is shown of it.
public struct SearchableContent: Sendable, Equatable, Codable {
    public let kind: SearchKind
    public let body: String
    /// Found by, but not shown: file names, link addresses, poll options.
    public let extra: [String]
    /// Present when the message is an image, video, audio or file attachment.
    public let attachment: SearchAttachment?

    public init(kind: SearchKind, body: String, extra: [String] = [], attachment: SearchAttachment? = nil) {
        self.kind = kind
        self.body = body
        self.extra = extra
        self.attachment = attachment
    }

    public func withThumbnail(_ thumbnail: MediaRef?) -> SearchableContent {
        guard let current = attachment, let thumbnail else { return self }
        return SearchableContent(
            kind: kind, body: body, extra: extra,
            attachment: SearchAttachment(
                mediaKind: current.mediaKind, filename: current.filename,
                mimeType: current.mimeType, sizeBytes: current.sizeBytes, thumbnail: thumbnail))
    }
}

/// One message of the index (DATA_MODELS §3b).
public struct SearchIndexEntry: Sendable, Equatable, Codable {
    public let room: RoomID
    public let event: EventID
    public let sender: UserID
    public let senderName: String?
    public let threadRoot: EventID?
    public let timestamp: Date
    public let content: SearchableContent

    public init(room: RoomID, event: EventID, sender: UserID, senderName: String?, threadRoot: EventID?, timestamp: Date, content: SearchableContent) {
        self.room = room
        self.event = event
        self.sender = sender
        self.senderName = senderName
        self.threadRoot = threadRoot
        self.timestamp = timestamp
        self.content = content
    }

    /// What the full-text column holds.
    public var indexText: String { SearchTokeniser.indexText([content.body] + content.extra + [senderName ?? ""]) }
}

/// Where the next page of results begins: after this row (newest first).
public struct SearchCursor: Sendable, Equatable, Codable {
    public let timestamp: Int64
    public let row: Int64
    public init(timestamp: Int64, row: Int64) {
        self.timestamp = timestamp
        self.row = row
    }
}

public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var room: RoomID?
    public var filter: SearchFilter

    public init(text: String, room: RoomID? = nil, filter: SearchFilter = .all) {
        self.text = text
        self.room = room
        self.filter = filter
    }
}

/// A row the index found.
public struct SearchIndexHit: Sendable, Equatable {
    public let entry: SearchIndexEntry
    public let cursor: SearchCursor
    /// When the SDK was last asked about this message.
    public let checkedAt: Date

    public init(entry: SearchIndexEntry, cursor: SearchCursor, checkedAt: Date) {
        self.entry = entry
        self.cursor = cursor
        self.checkedAt = checkedAt
    }
}

/// How far back a room has been read (MESSAGE_SEARCH §6).
public enum RoomSearchState: Int, Sendable, Codable {
    /// History from the anchor backwards is still to be read.
    case partial = 0
    case complete = 1
    /// The server doesn't give this room's history (any more).
    case blocked = 2
}

public struct RoomSearchCoverage: Sendable, Equatable {
    public let room: RoomID
    public let state: RoomSearchState
    /// History before this event is still to be read.
    public let anchor: EventID?
    public let oldest: Date?

    public init(room: RoomID, state: RoomSearchState, anchor: EventID?, oldest: Date?) {
        self.room = room
        self.state = state
        self.anchor = anchor
        self.oldest = oldest
    }
}

/// What the history lane reads next.
public enum SearchHistoryWork: Sendable, Equatable {
    /// A room that may have missed messages: its newest event IDs are compared with the index.
    case check(RoomID)
    /// Messages missed before this event, up to the next known one.
    case gap(RoomID, before: EventID)
    /// Messages whose keys were missing: this one and what was sent before it.
    case retry(RoomID, around: EventID)
    /// A room never read: starts at its newest event.
    case start(RoomID)
    /// The room's history before this event.
    case history(RoomID, before: EventID)

    public var room: RoomID {
        switch self {
        case .check(let room), .gap(let room, _), .retry(let room, _), .start(let room), .history(let room, _): room
        }
    }
}

/// Part of a room's history as the SDK gave it, oldest first.
public struct SearchHistorySlice: Sendable, Equatable, Codable {
    public var entries: [SearchIndexEntry]
    /// Messages without a key.
    public var undecryptable: [EventID]
    /// Events with nothing to search in them.
    public var other: [EventID]
    /// The oldest event outside a thread: where the next slice begins.
    public var oldest: EventID?
    public var oldestTime: Date?
    public var reachedStart: Bool

    public init(entries: [SearchIndexEntry] = [], undecryptable: [EventID] = [], other: [EventID] = [], oldest: EventID? = nil, oldestTime: Date? = nil, reachedStart: Bool = false) {
        self.entries = entries
        self.undecryptable = undecryptable
        self.other = other
        self.oldest = oldest
        self.oldestTime = oldestTime
        self.reachedStart = reachedStart
    }

    public var eventCount: Int { entries.count + undecryptable.count + other.count }
}

/// Something sync brought, as the index needs it.
public enum SearchLiveEvent: Sendable, Equatable, Codable {
    case message(SearchIndexEntry)
    case edit(RoomID, target: EventID, sender: UserID, SearchableContent)
    case undecryptable(RoomID, EventID)
    case removed(RoomID, EventID)

    public var room: RoomID {
        switch self {
        case .message(let entry): entry.room
        case .edit(let room, _, _, _), .undecryptable(let room, _), .removed(let room, _): room
        }
    }
}

/// What one sync response brought.
public struct SearchLiveBatch: Sendable, Equatable {
    public var events: [SearchLiveEvent]
    /// Rooms the response touched.
    public var touched: Set<RoomID>
    public var left: Set<RoomID>
    /// The first response after a start or a pause: any touched room may have missed messages.
    public var isCatchUp: Bool

    public init(events: [SearchLiveEvent] = [], touched: Set<RoomID> = [], left: Set<RoomID> = [], isCatchUp: Bool = false) {
        self.events = events
        self.touched = touched
        self.left = left
        self.isCatchUp = isCatchUp
    }
}

/// A write to the index, small and repeatable (applying it twice is the same as once).
public enum SearchIndexOperation: Sendable, Equatable, Codable {
    case live([SearchLiveEvent])
    /// `work` says what the slice answers: it moves the room's position.
    case slice(SearchHistorySlice, SliceTarget)
    /// These rooms may have missed messages.
    case check([RoomID])
    /// A room was checked; messages from `gapFrom` backwards are missing.
    case checked(RoomID, gapFrom: EventID?)
    case blocked(RoomID)
    case removeRooms([RoomID])

    public enum SliceTarget: Sendable, Equatable, Codable {
        case history(RoomID)
        case gap(RoomID, before: EventID)
        case retry(RoomID, around: EventID)

        public var room: RoomID {
            switch self {
            case .history(let room), .gap(let room, _), .retry(let room, _): room
            }
        }
    }
}

public struct SearchIndexStatistics: Sendable, Equatable {
    public var messages = 0
    public var bytes: Int64 = 0
    /// Messages known only by ID because their key is missing.
    public var undecryptable = 0

    public init(messages: Int = 0, bytes: Int64 = 0, undecryptable: Int = 0) {
        self.messages = messages
        self.bytes = bytes
        self.undecryptable = undecryptable
    }
}

/// What the index answers about a message it is about to show (MESSAGE_SEARCH FR-11).
public enum SearchRecheck: Sendable, Equatable {
    case unchanged
    case edited(SearchableContent)
    /// Deleted, or not readable any more.
    case gone
    /// Nobody could say (offline, a server error).
    case unchecked
}

/// One of a room's newest messages, as the server lists it.
public struct SearchRecentMessage: Sendable, Equatable {
    public let event: EventID
    /// Inside a thread: history can't be read from here (the SDK would page through the thread only).
    public let isThreaded: Bool

    public init(event: EventID, isThreaded: Bool) {
        self.event = event
        self.isThreaded = isThreaded
    }
}
