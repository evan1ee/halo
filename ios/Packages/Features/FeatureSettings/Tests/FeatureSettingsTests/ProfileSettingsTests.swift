import Foundation
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

    @Test("choosing a photo uploads it and shows it; removing clears it; a refused photo is reported")
    func avatar() async {
        final class Box: @unchecked Sendable { var data: Data?; var accept = true }
        let box = Box()
        let m = ProfileSettingsModel(actions: ProfileSettingsActions(
            loadName: { "Ann" }, saveName: { _ in true }, loadIgnored: { [] }, unignore: { _ in true },
            loadAvatar: { box.data }, setAvatar: { if box.accept { box.data = $0 }; return box.accept }, removeAvatar: { box.data = nil; return true }))
        await m.load()
        #expect(m.avatar == nil)
        await m.choosePhoto(Data([9]))
        #expect(m.avatar == Data([9]) && m.message == "Photo updated.")
        await m.removePhoto()
        #expect(m.avatar == nil)
        box.accept = false
        await m.choosePhoto(Data([1]))
        #expect(m.avatar == nil && m.message?.contains("couldn't be used") == true)

        // If the server hasn't synced the new avatar URL yet, keep the uploaded bytes visible.
        let delayed = ProfileSettingsModel(actions: ProfileSettingsActions(
            loadName: { "Ann" }, saveName: { _ in true }, loadIgnored: { [] }, unignore: { _ in true },
            loadAvatar: { nil }, setAvatar: { _ in true }, removeAvatar: { true }))
        await delayed.load()
        await delayed.choosePhoto(Data([5, 6]))
        #expect(delayed.avatar == Data([5, 6]) && delayed.message == "Photo updated.")
    }
}
