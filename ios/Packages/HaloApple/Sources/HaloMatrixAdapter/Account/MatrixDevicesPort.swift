import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `DevicesPort` over `GET /_matrix/client/v3/devices`. The SDK has no call that lists devices, so this is one of the few
/// direct HTTP calls (docs/adr/0018-devices-list-over-direct-http.md). The access token is read from the client for each call,
/// sent only to the account's own homeserver, and never logged.
public final class MatrixDevicesPort: DevicesPort {
    /// Sends one request and returns the body and status code. Injectable for tests.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    private let session: MatrixSessionPort
    private let transport: Transport

    public init(session: MatrixSessionPort, transport: @escaping Transport = MatrixDevicesPort.urlSession) {
        self.session = session
        self.transport = transport
    }

    public static let urlSession: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func devices() async throws(HaloError) -> [SessionDevice] {
        let client = try await session.signedInClient()
        let sdkSession: Session
        do { sdkSession = try client.session() } catch { throw ErrorMapper.map(error) }
        guard let base = URL(string: sdkSession.homeserverUrl), let scheme = base.scheme, scheme == "https" || scheme == "http" else {
            throw .internal(code: "DEVICES_URL")
        }
        var request = URLRequest(url: base.appending(path: "_matrix/client/v3/devices"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(sdkSession.accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let status: Int
        do { (data, status) = try await transport(request) } catch { throw ErrorMapper.map(error) }
        switch status {
        case 200: break
        case 401: throw .unauthorized(soft: false)
        case 403: throw .forbidden
        case 429, 500...599: throw .network(retryable: true)
        default: throw .internal(code: "DEVICES_HTTP")
        }
        return try Self.parse(data, currentDeviceID: sdkSession.deviceId)
    }

    public func canSignOutOthers() async -> Bool {
        guard let client = try? await session.signedInClient(), let sdkSession = try? client.session() else { return false }  // best-effort: a read; the caller falls back to a default and nothing changes
        return sdkSession.oauthData == nil
    }

    /// `POST /delete_devices` with password interactive authentication, as the password change does (ADR 0019).
    public func signOut(devices ids: [String], password: String) async throws(HaloError) {
        guard !ids.isEmpty else { return }
        let client = try await session.signedInClient()
        let sdkSession: Session
        do { sdkSession = try client.session() } catch { throw ErrorMapper.map(error) }
        guard sdkSession.oauthData == nil else { throw .unsupported("SIGN_OUT_OTHERS") }
        guard !ids.contains(sdkSession.deviceId) else { throw .invalidInput("CURRENT_DEVICE") }
        guard let base = URL(string: sdkSession.homeserverUrl), let scheme = base.scheme, scheme == "https" || scheme == "http" else {
            throw .internal(code: "DEVICES_URL")
        }
        let url = base.appending(path: "_matrix/client/v3/delete_devices")

        func send(auth: [String: Any]?) async throws(HaloError) -> (Data, Int) {
            var body: [String: Any] = ["devices": ids]
            if let auth { body["auth"] = auth }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(sdkSession.accessToken)", forHTTPHeaderField: "Authorization")
            do { request.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { throw .internal(code: "DEVICES_ENCODE") }
            do { return try await transport(request) } catch { throw ErrorMapper.map(error) }
        }

        let (first, firstStatus) = try await send(auth: nil)
        if firstStatus == 200 { return }
        guard firstStatus == 401, let challenge = MatrixAccountPasswordPort.json(first), let authSession = challenge["session"] as? String else {
            throw MatrixAccountPasswordPort.error(status: firstStatus, body: first)
        }
        let auth: [String: Any] = [
            "type": "m.login.password", "session": authSession,
            "identifier": ["type": "m.id.user", "user": sdkSession.userId], "password": password,
        ]
        let (second, secondStatus) = try await send(auth: auth)
        if secondStatus == 200 { return }
        throw MatrixAccountPasswordPort.error(status: secondStatus, body: second)
    }

    /// The `devices` array of the response, this device first, then newest `last_seen_ts` first. IP addresses are not read.
    static func parse(_ data: Data, currentDeviceID: String) throws(HaloError) -> [SessionDevice] {
        struct Response: Decodable {
            struct Device: Decodable {
                let device_id: String
                let display_name: String?
                let last_seen_ts: Double?
            }
            let devices: [Device]
        }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch { throw .internal(code: "DEVICES_DECODE") }
        let devices = response.devices.map { device in
            SessionDevice(
                id: device.device_id,
                displayName: device.display_name.flatMap { $0.isEmpty ? nil : $0 },
                lastSeen: device.last_seen_ts.map { Date(timeIntervalSince1970: $0 / 1000) },
                isCurrent: device.device_id == currentDeviceID)
        }
        return devices.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
        }
    }
}
