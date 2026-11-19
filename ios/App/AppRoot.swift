import FeatureAuth
import FeatureRoomList
import FeatureTimeline
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPlatform

/// Builds the object graph once at launch: platform and adapter implementations behind the ports,
/// the coordinators over them, and the view models over the coordinators.
@MainActor
final class AppRoot {
    let auth: AuthViewModel
    let roomList: RoomListViewModel
    let sync: SyncCoordinator
    let recovery: RecoveryViewModel
    /// `nil` when no push gateway is configured (Beta/Release until one is deployed).
    let push: PushCoordinator?
    private let timelinePort: MatrixTimelinePort
    private let media: MediaLoader

    init() {
        let namespace = Bundle.main.bundleIdentifier ?? "one.mbm.halo"
        let log = HaloLog(
            category: .session, sink: OSLogSink(subsystem: namespace),
            minimum: Self.minimumLogLevel, salt: Self.installSalt())

        // Shared with the notification extension: the Keychain access group and the App Group container.
        let keychain = HaloShared.keychain()
        let session = MatrixSessionPort(baseDirectory: HaloShared.storeDirectory())
        let sessionCoordinator = SessionCoordinator(port: session, keychain: keychain)
        let roomCoordinator = RoomListCoordinator(port: MatrixRoomListPort(session: session))

        timelinePort = MatrixTimelinePort(session: session)
        media = MediaLoader(port: MatrixMediaPort(session: session))
        recovery = RecoveryViewModel(coordinator: EncryptionCoordinator(port: MatrixEncryptionPort(session: session), session: sessionCoordinator))
        sync = SyncCoordinator(port: MatrixSyncPort(session: session), session: sessionCoordinator)
        push = Self.pushConfiguration().map {
            PushCoordinator(port: MatrixPushPort(session: session), session: sessionCoordinator, appID: $0.appID, gatewayURL: $0.gateway)
        }
        auth = AuthViewModel(coordinator: sessionCoordinator)
        roomList = RoomListViewModel(session: sessionCoordinator, rooms: roomCoordinator)
        log.info("app launched")
    }

    private static func pushConfiguration() -> (appID: String, gateway: URL)? {
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "HaloPushAppID") as? String, !appID.isEmpty,
              let raw = Bundle.main.object(forInfoDictionaryKey: "HaloPushGatewayURL") as? String, !raw.isEmpty,
              let gateway = URL(string: raw) else { return nil }
        return (appID, gateway)
    }

    /// A view model for the timeline of `room`; each screen gets its own coordinator and session.
    func makeTimeline(room: RoomID) -> TimelineViewModel {
        TimelineViewModel(coordinator: TimelineCoordinator(port: timelinePort, room: room), media: media)
    }

    private static var minimumLogLevel: LogLevel {
        #if DEBUG
        .debug
        #else
        .info
        #endif
    }

    /// A random per-install value for hashing identifiers in logs (SECURITY §6).
    private static func installSalt() -> UInt64 {
        let key = "logSalt"
        if let stored = UserDefaults.standard.object(forKey: key) as? UInt64 { return stored }
        let salt = UInt64.random(in: .min ... .max)
        UserDefaults.standard.set(salt, forKey: key)
        return salt
    }
}
