import Foundation
import HaloFoundation

/// GIF and sticker search through KLIPY (docs/features/COMPOSER_PANELS.md §6, D98, [VERIFIED F-KLIPY-1]).
///
/// KLIPY's integration rules shape everything here: media is loaded straight from the URLs the API returns, never
/// altered, stored or re-hosted; search and trending results keep KLIPY's order in their own grid. So Halo sends a GIF or
/// sticker as a text message whose body is the unmodified KLIPY media URL (end-to-end encrypted like any message) and
/// renders such messages by loading the URL directly.
public enum KlipyKind: String, Sendable, Codable, CaseIterable {
    case gifs
    case stickers
}

/// One file of an item (a size in one format).
public struct KlipyRendition: Sendable, Codable, Equatable {
    public let url: String
    public let width: Int
    public let height: Int
    public let size: Int

    public init(url: String, width: Int, height: Int, size: Int) {
        self.url = url
        self.width = width
        self.height = height
        self.size = size
    }

    public var aspectRatio: Double { width > 0 && height > 0 ? Double(width) / Double(height) : 1 }
}

/// A GIF or sticker from KLIPY, reduced to the two files Halo uses: a small animated preview for the grid and the file
/// whose URL is sent.
public struct KlipyItem: Sendable, Codable, Equatable, Identifiable {
    public let slug: String
    public let kind: KlipyKind
    public let title: String
    public let preview: KlipyRendition
    public let shared: KlipyRendition

    public var id: String { "\(kind.rawValue)/\(slug)" }

    public init(slug: String, kind: KlipyKind, title: String, preview: KlipyRendition, shared: KlipyRendition) {
        self.slug = slug
        self.kind = kind
        self.title = title
        self.preview = preview
        self.shared = shared
    }
}

/// A page of trending or search results, in KLIPY's order.
public struct KlipyPage: Sendable, Equatable {
    public let items: [KlipyItem]
    public let page: Int
    public let hasNext: Bool

    public init(items: [KlipyItem], page: Int, hasNext: Bool) {
        self.items = items
        self.page = page
        self.hasNext = hasNext
    }
}

/// Talks to KLIPY from the device (its rules forbid a proxy). Implemented in `HaloPlatform`.
public protocol KlipyPort: Sendable {
    func trending(_ kind: KlipyKind, page: Int) async throws(HaloError) -> KlipyPage
    func search(_ kind: KlipyKind, query: String, page: Int) async throws(HaloError) -> KlipyPage
    /// Tells KLIPY an item was sent (its share trigger); `query` is the search that found it, `nil` from trending.
    func registerShare(_ item: KlipyItem, query: String?) async throws(HaloError)
    /// Loads a KLIPY media file directly from its URL (memory only, never written to disk).
    func media(_ url: URL) async throws(HaloError) -> Data
}

/// Parses KLIPY's search/trending JSON (`{result, data: {data: [...], current_page, per_page, has_next}}`).
public enum KlipyResponseParser {
    /// Grid previews: small and animated first. Sent files: a medium GIF for GIFs (every client can show it), a
    /// medium WebP for stickers (keeps transparency).
    static let previewOrder: [(String, String)] = [("sm", "webp"), ("sm", "gif"), ("xs", "webp"), ("xs", "gif"), ("md", "webp"), ("md", "gif"), ("sm", "png")]
    static let sharedOrder: [KlipyKind: [(String, String)]] = [
        .gifs: [("md", "gif"), ("hd", "gif"), ("sm", "gif"), ("md", "webp"), ("hd", "webp")],
        .stickers: [("md", "webp"), ("hd", "webp"), ("md", "gif"), ("md", "png"), ("sm", "webp")],
    ]

    public static func page(from data: Data, kind: KlipyKind) throws(HaloError) -> KlipyPage {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) } catch { throw .internal(code: "KLIPY_DECODE") }
        guard envelope.result, let body = envelope.data else { throw .internal(code: "KLIPY_RESULT") }
        let items = (body.data ?? []).compactMap { raw -> KlipyItem? in
            guard raw.type == nil || raw.type == "gif" || raw.type == "sticker",
                  let slug = raw.slug, !slug.isEmpty, let files = raw.file,
                  let preview = pick(files, previewOrder),
                  let shared = pick(files, sharedOrder[kind] ?? [])
            else { return nil }  // ads and items without usable files are left out
            return KlipyItem(slug: slug, kind: kind, title: raw.title ?? "", preview: preview, shared: shared)
        }
        return KlipyPage(items: items, page: body.current_page ?? 1, hasNext: body.has_next ?? false)
    }

    private static func pick(_ files: [String: [String: KlipyRendition]], _ order: [(String, String)]) -> KlipyRendition? {
        for (size, format) in order {
            if let rendition = files[size]?[format], KlipyLink.mediaURL(in: rendition.url) != nil { return rendition }
        }
        return nil
    }

    private struct Envelope: Decodable {
        let result: Bool
        let data: Body?
    }

    private struct Body: Decodable {
        let data: [Raw]?
        let current_page: Int?
        let has_next: Bool?
    }

    private struct Raw: Decodable {
        let slug: String?
        let title: String?
        let type: String?
        let file: [String: [String: KlipyRendition]]?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            slug = try? container.decode(String.self, forKey: .slug)
            title = try? container.decode(String.self, forKey: .title)
            type = try? container.decode(String.self, forKey: .type)
            // A size may list formats Halo doesn't know or with missing fields; keep the readable ones.
            if let sizes = try? container.decode([String: [String: Lenient]].self, forKey: .file) {
                file = sizes.mapValues { $0.compactMapValues(\.rendition) }
            } else {
                file = nil
            }
        }

        enum CodingKeys: String, CodingKey { case slug, title, type, file }
    }

    private struct Lenient: Decodable {
        let rendition: KlipyRendition?
        init(from decoder: any Decoder) throws { rendition = try? KlipyRendition(from: decoder) }
    }
}

/// Recognises a message that is just a KLIPY media link, so the timeline can play it inline (D98).
public enum KlipyLink {
    static let extensions: Set<String> = ["gif", "webp", "png", "jpg"]

    /// The URL when `text` (trimmed) is exactly one https URL on a KLIPY media host (`static*.klipy.com` today) with an
    /// image extension; otherwise `nil`.
    public static func mediaURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), url.scheme == "https",
              let host = url.host?.lowercased(), host != "api.klipy.com", host.hasSuffix(".klipy.com"),
              extensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }
}

/// The user's KLIPY favourites and recently sent items, kept on this device for the signed-in account (D98). Holds item
/// metadata and URLs only, never media.
public struct KlipyShelf: Sendable, Codable, Equatable {
    public static let maxRecents = 30
    public static let maxFavourites = 200

    public private(set) var favourites: [KlipyItem] = []
    public private(set) var recents: [KlipyItem] = []

    public init(favourites: [KlipyItem] = [], recents: [KlipyItem] = []) {
        self.favourites = Array(favourites.prefix(Self.maxFavourites))
        self.recents = Array(recents.prefix(Self.maxRecents))
    }

    public func favourites(_ kind: KlipyKind) -> [KlipyItem] { favourites.filter { $0.kind == kind } }
    public func recents(_ kind: KlipyKind) -> [KlipyItem] { recents.filter { $0.kind == kind } }
    public func isFavourite(_ item: KlipyItem) -> Bool { favourites.contains { $0.id == item.id } }

    /// Adds at the front, or removes.
    public mutating func toggleFavourite(_ item: KlipyItem) {
        if isFavourite(item) {
            favourites.removeAll { $0.id == item.id }
        } else {
            favourites.insert(item, at: 0)
            if favourites.count > Self.maxFavourites { favourites.removeLast(favourites.count - Self.maxFavourites) }
        }
    }

    /// Moves `item` to the front of Recent.
    public mutating func recordSent(_ item: KlipyItem) {
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    }
}

/// Keeps the `KlipyShelf` of the signed-in account on this device.
public protocol KlipyShelfPort: Sendable {
    func load() async -> KlipyShelf
    func save(_ shelf: KlipyShelf) async
}
