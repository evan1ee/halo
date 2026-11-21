import Foundation
import Testing

@testable import FeatureSettings

@MainActor
@Suite("StickerPackSettingsModel")
struct StickerPackSettingsTests {
    final class Store: @unchecked Sendable {  // test double touched from one test at a time
        var rows = [
            StickerPackSettingsActions.Row(id: "a", name: "Cats", detail: "12 stickers"),
            StickerPackSettingsActions.Row(id: "b", name: "Dogs", detail: "3 stickers"),
        ]
        var failing = false
    }

    func model(_ store: Store) -> StickerPackSettingsModel {
        StickerPackSettingsModel(actions: .init(
            load: { store.rows },
            remove: { id in
                if store.failing { return false }
                store.rows.removeAll { $0.id == id }
                return true
            }))
    }

    @Test("removing a pack reloads the list; a failure keeps the row and says so")
    func removing() async {
        let store = Store()
        let model = model(store)
        await model.load()
        #expect(model.rows.map(\.id) == ["a", "b"] && model.loaded)
        store.failing = true
        await model.remove("a")
        #expect(model.rows.count == 2 && model.error != nil)
        store.failing = false
        await model.remove("a")
        #expect(model.rows.map(\.id) == ["b"] && model.error == nil)
    }
}
