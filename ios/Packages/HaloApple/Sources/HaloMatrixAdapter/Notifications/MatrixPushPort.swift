import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `PushPort` over the SDK's `set_pusher` (docs/matrix/PUSH_NOTIFICATIONS.md §2): an HTTP pusher, `event_id_only`,
/// whose default payload makes APNs run the notification extension (`mutable-content`) and shows a generic alert if
/// the extension is killed. It never contains a badge or message content (ADR-0015).
public final class MatrixPushPort: PushPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func register(deviceToken: Data, appID: String, gatewayURL: URL, deviceName: String) async throws(HaloError) {
        let client = try await session.signedInClient()
        let pushkey = deviceToken.map { String(format: "%02x", $0) }.joined()
        let data = HttpPusherData(url: gatewayURL.absoluteString, format: .eventIdOnly, defaultPayload: Self.defaultPayload)
        do {
            try await client.setPusher(
                identifiers: PusherIdentifiers(pushkey: pushkey, appId: appID), kind: .http(data: data),
                appDisplayName: "Halo", deviceDisplayName: deviceName, profileTag: nil, lang: "en", append: false)
        } catch { throw ErrorMapper.map(error) }
    }

    public func unregister(deviceToken: Data, appID: String) async throws(HaloError) {
        let client = try await session.signedInClient()
        let pushkey = deviceToken.map { String(format: "%02x", $0) }.joined()
        do { try await client.deletePusher(identifiers: PusherIdentifiers(pushkey: pushkey, appId: appID)) } catch { throw ErrorMapper.map(error) }
    }

    /// Generic text only; the real content is fetched and decrypted by the extension.
    static let defaultPayload = #"{"aps":{"mutable-content":1,"alert":{"title":"Halo","body":"New message"}}}"#
}
