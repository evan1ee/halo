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
}
