import Foundation
import HaloDomain
import HaloFoundation
import Synchronization

/// Records pusher registrations; can be told to fail the next one.
public final class FakePushPort: PushPort {
    public struct Registration: Sendable, Equatable {
        public let deviceToken: Data
        public let appID: String
        public let gatewayURL: URL

        public init(deviceToken: Data, appID: String, gatewayURL: URL) {
            self.deviceToken = deviceToken
            self.appID = appID
            self.gatewayURL = gatewayURL
        }
    }

    private struct State {
        var registrations: [Registration] = []
        var failures = 0
    }

    private let state = Mutex(State())

    public init() {}

    public var registrations: [Registration] { state.withLock { $0.registrations } }
    public func failNext(_ count: Int = 1) { state.withLock { $0.failures = count } }

    public func register(deviceToken: Data, appID: String, gatewayURL: URL, deviceName: String) async throws(HaloError) {
        let fail = state.withLock { state -> Bool in
            if state.failures > 0 { state.failures -= 1; return true }
            state.registrations.append(Registration(deviceToken: deviceToken, appID: appID, gatewayURL: gatewayURL))
            return false
        }
        if fail { throw .network(retryable: true) }
    }
}
