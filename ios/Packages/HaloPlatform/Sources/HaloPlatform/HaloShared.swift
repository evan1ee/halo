import Foundation

/// What the app and the notification extension share: the project namespace, the Keychain access group and the
/// App Group container (D63, docs/development/DEVELOPMENT_SETUP.md §3). Values come from the process's Info.plist
/// (`HaloNamespace`, `HaloKeychainAccessGroup`), which both targets fill from `Config/Base.xcconfig`.
public enum HaloShared {
    public static func namespace(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "HaloNamespace") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "one.mbm.halo"
    }

    /// The shared Keychain. The simulator's ad-hoc builds have no keychain entitlement (error -34018 otherwise), so
    /// they use the default group; a signed device build uses the shared one so the extension reads the app's session.
    public static func keychain(bundle: Bundle = .main) -> KeychainStore {
        #if targetEnvironment(simulator)
        let group: String? = nil
        #else
        let group = (bundle.object(forInfoDictionaryKey: "HaloKeychainAccessGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
        #endif
        return KeychainStore(service: namespace(bundle: bundle), accessGroup: group)
    }

    /// The SDK's store directory: inside the App Group container when the process is signed with it, else Application
    /// Support (unsigned simulator builds).
    public static func storeDirectory(bundle: Bundle = .main) -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.\(namespace(bundle: bundle))")
            ?? URL.applicationSupportDirectory
        return base.appendingPathComponent("matrix", isDirectory: true)
    }
}
