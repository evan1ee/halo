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
            followFocusFilter: true
        )
        store.save(updated)
        #expect(store.load() == updated)
        #expect(defaults.string(forKey: UserDefaultsPreferencesStore.appearanceKey) == "dark")
    }

    @Test("defaults for a new install, and values the Settings screen stored under the same keys read back (F-05: one store)")
    func defaultsAndStoredValues() throws {
        let suiteName = "one.mbm.halo.tests.prefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPreferencesStore(defaults: defaults)

        // New install: receipts public (AC-SET-2), typing notices on (SETTINGS §3), app-switcher blur on (D61),
        // no bots, appearance follows the system, Siri/Spotlight off (D88), Focus filters off (D104).
        let fresh = store.load()
        #expect(!fresh.privateReceipts && fresh.sendTypingNotices && fresh.privacyBlur)
        #expect(fresh.botSenders.isEmpty && fresh.appearance == .system)
        #expect(!fresh.chatsInSystemSearch && !fresh.followFocusFilter)

        // Values written by earlier builds under the `halo.*` keys stay readable; an unknown appearance reads as system.
        defaults.set(true, forKey: "halo.privateReadReceipts")
        defaults.set(false, forKey: "halo.sendTypingNotices")
        defaults.set(["@bot:x.org"], forKey: "halo.botSenders")
        defaults.set("sepia", forKey: "halo.appearance")
        let stored = store.load()
        #expect(stored.privateReceipts && !stored.sendTypingNotices && stored.botSenders == ["@bot:x.org"])
        #expect(stored.appearance == .system)
    }
}
