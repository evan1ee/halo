import Foundation
import HaloDomain
import HaloPlatform
import Testing

@Suite("UserDefaultsPreferencesStore (TD-02)")
struct UserDefaultsPreferencesStoreTests {
    @Test("Round-trips all preference fields using the established halo.* UserDefaults keys")
    func roundTripsAllFields() throws {
        let suiteName = "one.mbm.halo.tests.prefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsPreferencesStore(defaults: defaults)
        let initial = store.load()
        #expect(initial == PreferencesSnapshot())

        let updated = PreferencesSnapshot(
            privateReceipts: true,
            sendTypingNotices: false,
            privacyBlur: false,
            botSenders: ["@todo:example.org"],
            appearance: .dark,
            chatsInSystemSearch: true,
            followFocusFilter: true,
            mediaCacheRetention: MediaCacheRetention(maxSize: .mb500, expiry: .days7)
        )
        store.save(updated)
        #expect(store.load() == updated)
        #expect(defaults.string(forKey: UserDefaultsPreferencesStore.appearanceKey) == "dark")
        #expect(defaults.string(forKey: UserDefaultsPreferencesStore.mediaCacheMaxSizeKey) == "mb500")
        #expect(defaults.string(forKey: UserDefaultsPreferencesStore.mediaCacheExpiryKey) == "days7")
    }

    @Test("defaults for a new install, and values the Settings screen stored under the same keys read back (F-05: one store)")
    func defaultsAndStoredValues() throws {
        let suiteName = "one.mbm.halo.tests.prefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPreferencesStore(defaults: defaults)

        // New install: receipts public (AC-SET-2), typing notices on (SETTINGS §3), app-switcher blur on (D61),
        // no bots, appearance follows the system, Siri/Spotlight off (D88), Focus filters off (D104), media cache 1 GB / 30 days (D55).
        let fresh = store.load()
        #expect(!fresh.privateReceipts && fresh.sendTypingNotices && fresh.privacyBlur)
        #expect(fresh.botSenders.isEmpty && fresh.appearance == .system)
        #expect(!fresh.chatsInSystemSearch && !fresh.followFocusFilter)
        #expect(fresh.mediaCacheRetention == .defaultPolicy)

        // Values written by earlier builds under the `halo.*` keys stay readable; unknown enum values fall back to defaults.
        defaults.set(true, forKey: "halo.privateReadReceipts")
        defaults.set(false, forKey: "halo.sendTypingNotices")
        defaults.set(["@bot:x.org"], forKey: "halo.botSenders")
        defaults.set("sepia", forKey: "halo.appearance")
        defaults.set("10tb", forKey: UserDefaultsPreferencesStore.mediaCacheMaxSizeKey)
        defaults.set("forever", forKey: UserDefaultsPreferencesStore.mediaCacheExpiryKey)
        let stored = store.load()
        #expect(stored.privateReceipts && !stored.sendTypingNotices && stored.botSenders == ["@bot:x.org"])
        #expect(stored.appearance == .system)
        #expect(stored.mediaCacheRetention == .defaultPolicy)
    }
}
