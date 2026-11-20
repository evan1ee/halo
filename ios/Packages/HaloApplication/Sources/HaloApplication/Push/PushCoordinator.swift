import Foundation
import HaloDomain
import HaloFoundation

/// Registers the device's APNs token as a pusher once there is both a token and a ready session, and again when
/// either changes (docs/matrix/PUSH_NOTIFICATIONS.md §2). A failed registration is retried on the next trigger
/// (token refresh, new session, `retry()`); it is never an error the user must handle.
public actor PushCoordinator {
    private let port: any PushPort
    private let session: SessionCoordinator
    private let appID: String
    private let gatewayURL: URL
    private let deviceName: String
    private var token: Data?
    private var sessionReady = false
    private var registered: Data?
    private var sessionTask: Task<Void, Never>?

    public init(port: any PushPort, session: SessionCoordinator, appID: String, gatewayURL: URL, deviceName: String = "Halo (iPhone)") {
        self.port = port
        self.session = session
        self.appID = appID
        self.gatewayURL = gatewayURL
        self.deviceName = deviceName
    }

    deinit { sessionTask?.cancel() }

    /// Starts following the session. Call once at launch.
    public func begin() async {
        guard sessionTask == nil else { return }
        let states = await session.states()
        sessionTask = Task { [weak self] in
            for await state in states {
                var ready = false
                if case .ready = state { ready = true }
                await self?.setSessionReady(ready)
            }
        }
    }

    /// The system handed out (or refreshed) the APNs device token.
    public func deviceTokenReceived(_ token: Data) async {
        self.token = token
        await registerIfPossible()
    }

    /// Removes the pusher from the homeserver. Call before the session ends (it needs the session). Best effort: a failure
    /// must not block signing out, and the homeserver drops a pusher whose gateway rejects the token anyway.
    public func unregister() async {
        guard let token else { return }
        try? await port.unregister(deviceToken: token, appID: appID)
        registered = nil
    }

    /// Tries again after a failure.
    public func retry() async { await registerIfPossible() }

    private func setSessionReady(_ ready: Bool) async {
        sessionReady = ready
        if !ready { registered = nil }  // a new session must register again
        await registerIfPossible()
    }

    private func registerIfPossible() async {
        guard sessionReady, let token, registered != token else { return }
        do {
            try await port.register(deviceToken: token, appID: appID, gatewayURL: gatewayURL, deviceName: deviceName)
            registered = token
        } catch {
            // Left unregistered: the next trigger tries again.
        }
    }
}
