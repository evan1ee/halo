import Foundation
import HaloDomain
import HaloFoundation

/// `KlipyPort` over KLIPY's REST API (docs/features/COMPOSER_PANELS.md §6, D98, [VERIFIED F-KLIPY-1]).
///
/// A documented direct HTTP path (AGENTS §14): requests go from the device to `api.klipy.com` and media straight to
/// KLIPY's CDN, as KLIPY's rules require. Nothing Halo-specific is sent: the app key, the search text, the region, a
/// content filter, and `customer_id`, a random per-install UUID that is never a Matrix ID. The session is ephemeral (no
/// cookies, no disk cache), so no KLIPY media is written to disk.
public struct KlipyClient: KlipyPort {
    public static let infoPlistKey = "HaloKlipyAPIKey"
    static let base = "https://api.klipy.com/api/v1/"
    static let perPage = 24
    /// Mild filtering by default; partner-level filtering lives in KLIPY's Partner Panel.
    static let contentFilter = "medium"

    private let appKey: String
    private let customerID: String
    private let locale: String?
    private let session: URLSession

    public init(appKey: String, customerID: String, locale: String? = Locale.current.region?.identifier.lowercased(), session: URLSession? = nil) {
        self.appKey = appKey
        self.customerID = customerID
        self.locale = locale
        self.session = session ?? Self.makeSession()
    }

    /// The client for this build, or `nil` when no key was configured (`HALO_KLIPY_API_KEY` in `Config/Local.xcconfig`).
    public static func configured(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> KlipyClient? {
        guard let key = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
              !key.trimmingCharacters(in: .whitespaces).isEmpty, !key.hasPrefix("$(")
        else { return nil }
        return KlipyClient(appKey: key, customerID: customerID(defaults))
    }

    /// A random identifier for this installation, stable across launches (KLIPY asks for a consistent `customer_id`).
    static func customerID(_ defaults: UserDefaults) -> String {
        let name = "halo.klipy.customerID"
        if let existing = defaults.string(forKey: name), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: name)
        return fresh
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    // MARK: KlipyPort

    public func trending(_ kind: KlipyKind, page: Int) async throws(HaloError) -> KlipyPage {
        let data = try await get(listURL(kind, endpoint: "trending", query: nil, page: page))
        return try KlipyResponseParser.page(from: data, kind: kind)
    }

    public func search(_ kind: KlipyKind, query: String, page: Int) async throws(HaloError) -> KlipyPage {
        let data = try await get(listURL(kind, endpoint: "search", query: query, page: page))
        return try KlipyResponseParser.page(from: data, kind: kind)
    }

    public func registerShare(_ item: KlipyItem, query: String?) async throws(HaloError) {
        guard let slug = item.slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: Self.base + appKey + "/\(item.kind.rawValue)/share/\(slug)")
        else { throw .invalidInput("KLIPY_SLUG") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["customer_id": customerID]
        if let query { body["q"] = query }
        request.httpBody = try? JSONEncoder().encode(body)
        _ = try await send(request)
    }

    public func media(_ url: URL) async throws(HaloError) -> Data {
        guard KlipyLink.mediaURL(in: url.absoluteString) != nil else { throw .invalidInput("NOT_KLIPY_MEDIA") }
        return try await send(URLRequest(url: url))
    }

    // MARK: Requests

    func listURL(_ kind: KlipyKind, endpoint: String, query: String?, page: Int) throws(HaloError) -> URL {
        guard var components = URLComponents(string: Self.base + appKey + "/\(kind.rawValue)/\(endpoint)") else { throw .internal(code: "KLIPY_URL") }
        var items = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "per_page", value: String(Self.perPage)),
            URLQueryItem(name: "customer_id", value: customerID),
            URLQueryItem(name: "content_filter", value: Self.contentFilter),
        ]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        if let locale, !locale.isEmpty { items.append(URLQueryItem(name: "locale", value: locale)) }
        components.queryItems = items
        guard let url = components.url else { throw .internal(code: "KLIPY_URL") }
        return url
    }

    private func get(_ url: URL) async throws(HaloError) -> Data { try await send(URLRequest(url: url)) }

    private func send(_ request: URLRequest) async throws(HaloError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch {
            throw .network(retryable: true)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw .forbidden
        case 404: throw .notFound
        case 429, 500...: throw .network(retryable: true)
        default: throw .network(retryable: false)
        }
    }
}
