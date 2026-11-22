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
            chatsInSystemSearch: true
        )
        store.save(updated)
        #expect(store.load() == updated)
        #expect(defaults.string(forKey: UserDefaultsPreferencesStore.appearanceKey) == "dark")
    }
}
