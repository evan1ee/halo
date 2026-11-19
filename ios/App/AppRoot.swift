import FeatureAuth
import FeatureRoomList
import Foundation
import HaloApplication
import HaloFoundation
import HaloMatrixAdapter
import HaloPlatform

/// Builds the object graph once at launch: platform and adapter implementations behind the ports,
/// the coordinators over them, and the view models over the coordinators.
@MainActor
final class AppRoot {
    let auth: AuthViewModel
    let roomList: RoomListViewModel

    init() {
        let namespace = Bundle.main.bundleIdentifier ?? "one.mbm.halo"
        let log = HaloLog(
            category: .session, sink: OSLogSink(subsystem: namespace),
            minimum: Self.minimumLogLevel, salt: Self.installSalt())

        // The access group is added once the app is signed with a team (M1, shared with the NSE).
        let keychain = KeychainStore(service: namespace, accessGroup: nil)
        let session = MatrixSessionPort(baseDirectory: Self.storeDirectory(namespace: namespace))
        let sessionCoordinator = SessionCoordinator(port: session, keychain: keychain)
        let roomCoordinator = RoomListCoordinator(port: MatrixRoomListPort(session: session))

        auth = AuthViewModel(coordinator: sessionCoordinator)
        roomList = RoomListViewModel(session: sessionCoordinator, rooms: roomCoordinator)
        log.info("app launched")
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

    /// The App Group container when the app is signed with it, else Application Support (unsigned simulator builds).
    private static func storeDirectory(namespace: String) -> URL {
        let fileManager = FileManager.default
        let base = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.\(namespace)")
            ?? URL.applicationSupportDirectory
        return base.appendingPathComponent("matrix", isDirectory: true)
    }
}
