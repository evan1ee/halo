import Testing
@testable import FeatureSettings

@MainActor
@Suite("ProfileSettingsModel")
struct ProfileSettingsTests {
    private final class Log: @unchecked Sendable { var saved: [String] = []; var unignored: [String] = []; var fail = false }

    private func model(_ log: Log, name: String? = "Ann", ignored: [String]? = ["@bob:x.org"]) -> ProfileSettingsModel {
        ProfileSettingsModel(actions: ProfileSettingsActions(
            loadName: { name }, saveName: { log.saved.append($0); return !log.fail },
            loadIgnored: { ignored }, unignore: { log.unignored.append($0); return !log.fail }))
    }

    @Test("loads the name and the ignored list; saving needs a changed, non-empty name")
    func save() async {
        let log = Log()
        let m = model(log)
        await m.load()
        #expect(m.name == "Ann" && m.ignored == ["@bob:x.org"] && !m.canSave)
        m.name = "  "
        #expect(!m.canSave)
        m.name = " Anna "
        #expect(m.canSave)
        await m.save()
        #expect(log.saved == ["Anna"] && !m.canSave && m.message == "Saved.")
    }

    @Test("a failed save or unignore is reported and keeps the state; unignoring removes the entry")
    func failures() async {
        let log = Log()
        let m = model(log)
        await m.load()
        m.name = "Zed"
        log.fail = true
        await m.save()
        #expect(m.canSave && m.message?.contains("couldn't be saved") == true)
        await m.unignore("@bob:x.org")
        #expect(m.ignored == ["@bob:x.org"])
        log.fail = false
        await m.unignore("@bob:x.org")
        #expect(m.ignored.isEmpty)
    }

    @Test("a profile that can't be loaded leaves the screen unloaded")
    func loadFails() async {
        let m = model(Log(), name: nil)
        await m.load()
        #expect(!m.isLoaded && m.message != nil)
    }
}
