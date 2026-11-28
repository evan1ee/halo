import Foundation
import HaloDomain

/// `UserDefaults`-backed `PreferencesPort` implementation (TD-02, ADR-0022).
///
/// Uses the established `halo.*` keys so existing user settings migrate without data loss.
public struct UserDefaultsPreferencesStore: PreferencesPort, Sendable {
    /// `@unchecked Sendable` justification (AGENTS.md §9): `UserDefaults` is documented by Apple as thread-safe.
    private struct Box: @unchecked Sendable { let defaults: UserDefaults }
    private let box: Box

    public static let privateReceiptsKey = "halo.privateReadReceipts"
    public static let sendTypingNoticesKey = "halo.sendTypingNotices"
    public static let privacyBlurKey = "halo.privacyBlur"
    public static let appearanceKey = "halo.appearance"
    public static let botSendersKey = "halo.botSenders"
    public static let lastSeenWhatsNewVersionKey = "halo.lastSeenWhatsNewVersion"
    public static let chatsInSystemSearchKey = "halo.chatsInSystemSearch"
    public static let followFocusFilterKey = "halo.followFocusFilter"
    public static let searchHistoryPausedKey = "halo.search.historyPaused"
    public static let searchHistoryOnMobileDataKey = "halo.search.onMobileData"
    public static let mediaCacheMaxSizeKey = "halo.mediaCache.maxSize"
    public static let mediaCacheExpiryKey = "halo.mediaCache.expiry"

    public init(defaults: UserDefaults = .standard) {
        box = Box(defaults: defaults)
    }

    public func load() -> PreferencesSnapshot {
        let d = box.defaults
        let maxSize = MediaCacheSizeLimit(rawValue: d.string(forKey: Self.mediaCacheMaxSizeKey) ?? "") ?? MediaCacheRetention.defaultPolicy.maxSize
        let expiry = MediaCacheExpiry(rawValue: d.string(forKey: Self.mediaCacheExpiryKey) ?? "") ?? MediaCacheRetention.defaultPolicy.expiry
        return PreferencesSnapshot(
            privateReceipts: d.bool(forKey: Self.privateReceiptsKey),
            sendTypingNotices: d.object(forKey: Self.sendTypingNoticesKey) as? Bool ?? true,
            privacyBlur: d.object(forKey: Self.privacyBlurKey) as? Bool ?? true,
            botSenders: d.stringArray(forKey: Self.botSendersKey) ?? [],
            appearance: AppAppearance(rawValue: d.string(forKey: Self.appearanceKey) ?? "") ?? .system,
            lastSeenWhatsNewVersion: d.string(forKey: Self.lastSeenWhatsNewVersionKey),
            chatsInSystemSearch: d.bool(forKey: Self.chatsInSystemSearchKey),
            followFocusFilter: d.bool(forKey: Self.followFocusFilterKey),
            searchHistoryPaused: d.bool(forKey: Self.searchHistoryPausedKey),
            searchHistoryOnMobileData: d.bool(forKey: Self.searchHistoryOnMobileDataKey),
            mediaCacheRetention: MediaCacheRetention(maxSize: maxSize, expiry: expiry)
        )
    }

    public func save(_ snapshot: PreferencesSnapshot) {
        let d = box.defaults
        d.set(snapshot.privateReceipts, forKey: Self.privateReceiptsKey)
        d.set(snapshot.sendTypingNotices, forKey: Self.sendTypingNoticesKey)
        d.set(snapshot.privacyBlur, forKey: Self.privacyBlurKey)
        d.set(snapshot.botSenders, forKey: Self.botSendersKey)
        d.set(snapshot.appearance.rawValue, forKey: Self.appearanceKey)
        d.set(snapshot.lastSeenWhatsNewVersion, forKey: Self.lastSeenWhatsNewVersionKey)
        d.set(snapshot.chatsInSystemSearch, forKey: Self.chatsInSystemSearchKey)
        d.set(snapshot.followFocusFilter, forKey: Self.followFocusFilterKey)
        d.set(snapshot.searchHistoryPaused, forKey: Self.searchHistoryPausedKey)
        d.set(snapshot.searchHistoryOnMobileData, forKey: Self.searchHistoryOnMobileDataKey)
        d.set(snapshot.mediaCacheRetention.maxSize.rawValue, forKey: Self.mediaCacheMaxSizeKey)
        d.set(snapshot.mediaCacheRetention.expiry.rawValue, forKey: Self.mediaCacheExpiryKey)
    }
}
