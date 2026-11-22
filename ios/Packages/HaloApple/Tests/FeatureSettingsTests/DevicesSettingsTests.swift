import Foundation
import Testing

@testable import FeatureSettings

@MainActor
@Suite("DevicesSettingsModel")
struct DevicesSettingsTests {
    final class Store: @unchecked Sendable {  // test double touched from one test at a time
        var rows: [DevicesSettingsActions.Row]? = [
            .init(id: "ME", name: "Halo (iPhone)", lastSeen: nil, isCurrent: true),
            .init(id: "OLD", name: "Old phone", lastSeen: Date(timeIntervalSinceNow: -3 * 86_400), isCurrent: false),
            .init(id: "X", name: "X", lastSeen: nil, isCurrent: false),
        ]
    }

    @Test("the sessions load; the current one says so, others say when they were last seen")
    func loading() async {
        let store = Store()
        let model = DevicesSettingsModel(actions: .init(load: { store.rows }))
        await model.load()
        #expect(model.loaded && model.error == nil && model.rows.count == 3)
        #expect(model.detail(model.rows[0]) == "This device")
        #expect(model.detail(model.rows[1]).hasPrefix("Last active "))
        #expect(model.detail(model.rows[2]) == "Last active unknown")
    }

    @Test("a failed reload keeps the list and says so; a later success clears the message")
    func failing() async {
        let store = Store()
        let model = DevicesSettingsModel(actions: .init(load: { store.rows }))
        await model.load()
        store.rows = nil
        await model.load()
        #expect(model.rows.count == 3 && model.error != nil)
        store.rows = []
        await model.load()
        #expect(model.rows.isEmpty && model.error == nil)
    }
}
