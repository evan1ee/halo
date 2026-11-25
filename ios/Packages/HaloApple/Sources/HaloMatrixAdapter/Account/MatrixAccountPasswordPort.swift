import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `AccountPasswordPort` over `POST /_matrix/client/v3/account/password` with password interactive authentication. The SDK has
/// no call for it, so this is a documented direct HTTP call (docs/adr/0019-change-password-over-direct-http.md). The passwords
/// live in memory only for the two requests, are sent only to the account's own homeserver, and are never logged.
public final class MatrixAccountPasswordPort: AccountPasswordPort {
    private let session: MatrixSessionPort
    private let transport: MatrixDevicesPort.Transport

    public init(session: MatrixSessionPort, transport: @escaping MatrixDevicesPort.Transport = MatrixDevicesPort.urlSession) {
        self.session = session
        self.transport = transport
    }

    public func canChangePassword() async -> Bool {
        guard let client = try? await session.signedInClient(), let sdkSession = try? client.session() else { return false }  // best-effort: a read; the caller falls back to a default and nothing changes
        return sdkSession.oauthData == nil
    }

    public func changePassword(current: String, new: String) async throws(HaloError) {
        let client = try await session.signedInClient()
        let sdkSession: Session
        do { sdkSession = try client.session() } catch { throw ErrorMapper.map(error) }
        guard sdkSession.oauthData == nil else { throw .unsupported("PASSWORD_MANAGED_EXTERNALLY") }
        guard let base = URL(string: sdkSession.homeserverUrl), let scheme = base.scheme, scheme == "https" || scheme == "http" else {
            throw .internal(code: "PASSWORD_URL")
        }
        let user = sdkSession.userId
        let url = base.appending(path: "_matrix/client/v3/account/password")

        func send(auth: [String: Any]?) async throws(HaloError) -> (Data, Int) {
            var body: [String: Any] = ["new_password": new, "logout_devices": false]
            if let auth { body["auth"] = auth }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(sdkSession.accessToken)", forHTTPHeaderField: "Authorization")
            do { request.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { throw .internal(code: "PASSWORD_ENCODE") }
            do { return try await transport(request) } catch { throw ErrorMapper.map(error) }
        }

        // Step 1: the homeserver answers 401 with the interactive-authentication session.
        let (first, firstStatus) = try await send(auth: nil)
        if firstStatus == 200 { return }
        guard firstStatus == 401, let challenge = Self.json(first), let authSession = challenge["session"] as? String else {
            throw Self.error(status: firstStatus, body: first)
        }
        // Step 2: the same request, proving the current password.
        let auth: [String: Any] = [
            "type": "m.login.password", "session": authSession,
            "identifier": ["type": "m.id.user", "user": user], "password": current,
        ]
        let (second, secondStatus) = try await send(auth: auth)
        if secondStatus == 200 { return }
        throw Self.error(status: secondStatus, body: second)
    }

    static func json(_ data: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }

    /// Maps a failed answer: a wrong current password (401 `M_FORBIDDEN`), a refused new password (400 `M_WEAK_PASSWORD` and
    /// kin), too many attempts and server trouble.
    static func error(status: Int, body: Data) -> HaloError {
        let code = json(body)?["errcode"] as? String
        switch (status, code) {
        case (401, _), (403, "M_FORBIDDEN"): return .invalidInput("CURRENT_PASSWORD")
        case (400, "M_WEAK_PASSWORD"), (400, "M_PASSWORD_TOO_SHORT"), (400, "M_PASSWORD_NO_DIGIT"), (400, "M_PASSWORD_NO_UPPERCASE"),
             (400, "M_PASSWORD_NO_LOWERCASE"), (400, "M_PASSWORD_NO_SYMBOL"), (400, "M_PASSWORD_IN_DICTIONARY"):
            return .invalidInput("NEW_PASSWORD")
        case (403, _): return .forbidden
        case (429, _), (500...599, _): return .network(retryable: true)
        default: return .internal(code: "PASSWORD_HTTP")
        }
    }
}
