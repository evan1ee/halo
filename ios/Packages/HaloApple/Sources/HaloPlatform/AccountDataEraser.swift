import Foundation
import HaloDomain
import HaloFoundation

/// Where the app keeps one account's data on disk outside the Keychain (docs/data/PERSISTENCE.md, AC-AUTH-4, AC-SEC-4).
public struct AccountDataLocations: Sendable {
    /// The SDK's stores and `halo/halo.sqlite` (records, drafts, read intents, audit, bot tasks).
    public let stores: URL
    /// Items the share extension staged for the app.
    public let shareInbox: URL
    /// The message search index and its holding file.
    public let search: URL
    /// The chats offered to Siri, Shortcuts, Spotlight and the widgets.
    public let chatShortcuts: URL
    /// Derived receipt event-time cache (GA-28, M19-7); optional for test fixtures that construct custom locations.
    public let eventTimeCache: URL?

    public init(stores: URL, shareInbox: URL, search: URL, chatShortcuts: URL, eventTimeCache: URL? = nil) {
        self.stores = stores
        self.shareInbox = shareInbox
        self.search = search
        self.chatShortcuts = chatShortcuts
        self.eventTimeCache = eventTimeCache
    }

    public static func standard(bundle: Bundle = .main) -> AccountDataLocations {
        AccountDataLocations(
            stores: HaloShared.storeDirectory(bundle: bundle),
            shareInbox: HaloShared.shareInboxDirectory(bundle: bundle),
            search: HaloShared.searchDirectory(),
            chatShortcuts: SystemChatShortcutStore.defaultFile(bundle: bundle),
            eventTimeCache: HaloShared.eventTimeCacheFile())
    }

    var all: [URL] { [stores, shareInbox, search, chatShortcuts] + (eventTimeCache.map { [$0] } ?? []) }
}

/// Removes what an account left on the device, and keeps it out of backups (AC-AUTH-4, AC-SEC-4).
public enum AccountDataEraser {
    /// The places that still hold something.
    public static func leftovers(in locations: AccountDataLocations) -> [URL] {
        locations.all.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Deletes every per-account folder and file, the account's database key and its KLIPY shelf, and the chats offered to
    /// the system. Used on sign-out, and at launch when no session is stored but files are (a device restored from a backup,
    /// an app killed while signing out): the session's Keychain items never leave the device, so such files can't be opened.
    public static func erase(
        _ locations: AccountDataLocations, account: UserID?, keychain: any KeychainPort,
        shortcuts: (any ChatShortcutPort)? = nil, defaults: UserDefaults = .standard
    ) async {
        for url in locations.all { try? FileManager.default.removeItem(at: url) }
        await shortcuts?.clear()
        if let account {
            try? await keychain.delete(.haloDatabaseKey(account))  // best-effort: a key that is already gone is the goal; the rest of the erase must still run
            KlipyShelfStore(account: account, defaults: defaults).erase()
        }
    }

    /// Keeps the stores and everything staged for the app out of iCloud and device backups. Call at launch: the folders are
    /// created by other code, so a folder that doesn't exist yet is skipped and flagged the next time.
    public static func excludeFromBackup(_ locations: AccountDataLocations) {
        for var url in locations.all where FileManager.default.fileExists(atPath: url.path) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    /// Creates the folders that hold stores, flagged as excluded, so nothing is written to them before the flag is set.
    public static func prepareStoreFolders(_ locations: AccountDataLocations) {
        for url in [locations.stores, locations.shareInbox] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        excludeFromBackup(locations)
    }
}
