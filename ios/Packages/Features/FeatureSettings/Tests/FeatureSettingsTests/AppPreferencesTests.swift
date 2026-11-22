import Foundation
import Testing
@testable import FeatureSettings

@Suite("AppPreferences")
struct AppPreferencesTests {
    @Test("receipts are public by default; the choice is stored at once and read back by a new instance (AC-SET-2 setting)")
    func privateReceipts() throws {
        let name = "halo.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences(defaults: defaults).privateReceipts == false)
        AppPreferences(defaults: defaults).privateReceipts = true
        #expect(AppPreferences(defaults: defaults).privateReceipts == true)
        AppPreferences(defaults: defaults).privateReceipts = false
        #expect(AppPreferences(defaults: defaults).privateReceipts == false)
    }

    @Test("appearance follows the system by default, is stored, and an unknown value reads as system")
    func appearance() throws {
        let name = "halo.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences(defaults: defaults).appearance == .system)
        AppPreferences(defaults: defaults).appearance = .dark
        #expect(AppPreferences(defaults: defaults).appearance == .dark)
        defaults.set("sepia", forKey: AppPreferences.appearanceKey)
        #expect(AppPreferences(defaults: defaults).appearance == .system)
    }

    @Test("the bot allowlist is empty by default and stored as given")
    func botSenders() throws {
        let name = "halo.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences(defaults: defaults).botSenders.isEmpty)
        AppPreferences(defaults: defaults).botSenders = ["@bot:x.org"]
        #expect(AppPreferences(defaults: defaults).botSenders == ["@bot:x.org"])
    }

    @Test("typing notices are on by default and stored immediately (SETTINGS §3)")
    func sendTypingNotices() throws {
        let name = "halo.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences(defaults: defaults).sendTypingNotices == true)
        AppPreferences(defaults: defaults).sendTypingNotices = false
        #expect(AppPreferences(defaults: defaults).sendTypingNotices == false)
        AppPreferences(defaults: defaults).sendTypingNotices = true
        #expect(AppPreferences(defaults: defaults).sendTypingNotices == true)
    }

    @Test("app-switcher privacy blur is on by default and stored immediately (D61, SECURITY §4)")
    func privacyBlur() throws {
        let name = "halo.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppPreferences(defaults: defaults).privacyBlur == true)
        AppPreferences(defaults: defaults).privacyBlur = false
        #expect(AppPreferences(defaults: defaults).privacyBlur == false)
        AppPreferences(defaults: defaults).privacyBlur = true
        #expect(AppPreferences(defaults: defaults).privacyBlur == true)
    }
}
