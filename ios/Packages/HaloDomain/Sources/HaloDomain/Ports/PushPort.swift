import Foundation
import HaloFoundation

/// Registers this device's APNs token with the homeserver as an HTTP pusher (docs/matrix/PUSH_NOTIFICATIONS.md §2).
/// Implemented by `HaloMatrixAdapter`; faked in `HaloTestSupport`. Pushes are hints only (D65): the payload carries
/// no badge and no message content.
public protocol PushPort: Sendable {
    /// Registers (or refreshes) the pusher for the signed-in account. `gatewayURL` is the push gateway's notify endpoint
    /// as the homeserver reaches it. Throws `.unauthorized` without a session.
    func register(deviceToken: Data, appID: String, gatewayURL: URL, deviceName: String) async throws(HaloError)

    /// Removes this device's pusher from the homeserver (sign-out); the homeserver stops pushing to the token.
    func unregister(deviceToken: Data, appID: String) async throws(HaloError)
}
