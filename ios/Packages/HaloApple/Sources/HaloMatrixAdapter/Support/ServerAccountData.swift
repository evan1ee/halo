import Foundation
import HaloFoundation
import MatrixRustSDK

/// Authenticated GETs of the Client-Server API for what the FFI has no call for: custom room state (V-ST-1) and account data
/// as the server holds it now. The access token is never logged. On a 401 the SDK is asked to refresh by making one of its
/// own authenticated requests, then the call is repeated once (V-ST-2).
struct ClientServerGET: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    struct Forbidden: Error {}

    let fetch: Fetch

    /// No disk cache for authenticated responses (they hold room state), no cookies.
    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The response body, `nil` for 404 (no such state or account data), an error for anything else that isn't 200.
    func get(_ client: Client, _ path: String, query: [URLQueryItem] = [], retried: Bool = false) async throws -> Data? {
        let sdkSession = try client.session()
        guard var components = URLComponents(string: sdkSession.homeserverUrl) else { throw URLError(.badURL) }
        components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? "/_matrix/client/v3/\(path)" : components.percentEncodedPath + "/_matrix/client/v3/\(path)"
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(sdkSession.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await fetch(request)
        switch response.statusCode {
        case 200: return data
        case 404: return nil
        case 401 where !retried:
            _ = try? await client.getProfile(userId: sdkSession.userId)  // a network request of the SDK refreshes an expired token
            return try await get(client, path, query: query, retried: true)
        case 403: throw Forbidden()
        default: throw URLError(.badServerResponse)
        }
    }

    static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? component
    }
}

/// Changing account data that holds more than the one value being changed. `Client.accountData` answers from the SDK's store,
/// which is empty until the first sync is stored (seconds on a large account) and behind a write until sync echoes it, so
/// writing back a change of that copy drops everything the server had. The base is therefore read from the server, and
/// nothing is written when it can't be read (D120).
struct ServerAccountData: Sendable {
    /// The server's content of a type; `nil` when there is none.
    let read: @Sendable (_ type: String) async throws -> Data?
    let write: @Sendable (_ type: String, _ content: String) async throws -> Void

    init(read: @escaping @Sendable (String) async throws -> Data?, write: @escaping @Sendable (String, String) async throws -> Void) {
        self.read = read
        self.write = write
    }

    init(_ client: Client, fetch: @escaping ClientServerGET.Fetch = ClientServerGET.urlSessionFetch) {
        self.init(
            read: { type in
                let user = ClientServerGET.escape(try client.session().userId)
                return try await ClientServerGET(fetch: fetch).get(client, "user/\(user)/account_data/\(ClientServerGET.escape(type))")
            },
            write: { type, content in try await client.setAccountData(eventType: type, content: content) })
    }

    /// The server's content; throws when it can't be read or isn't a JSON object (never taken for "nothing there").
    func content(_ type: String) async throws -> [String: Any]? {
        guard let data = try await read(type) else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HaloError.internal(code: "ACCOUNT_DATA_MALFORMED")
        }
        return object
    }

    /// Writes `change` of the server's content; `nil` from `change` leaves it alone.
    func update(_ type: String, _ change: ([String: Any]?) throws -> [String: Any]?) async throws {
        guard let updated = try change(try await content(type)) else { return }
        try await write(type, String(decoding: try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]), as: UTF8.self))
    }

    /// For reading only: the SDK's copy (works offline), or the server's while the store has none. Throws when neither is known.
    func storedOrServer(_ type: String, _ client: Client) async throws -> Data? {
        if let json = try await client.accountData(eventType: type) { return Data(json.utf8) }
        return try await read(type)
    }
}
