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

@MainActor
@Suite("DevicesSettingsModel sign-out (M18-13)")
struct DevicesSignOutTests {
    final class Calls: @unchecked Sendable {  // test double touched from one test at a time
        var signedOut: [[String]] = []
        var result: DevicesSettingsActions.SignOutFailure?
        var rows: [DevicesSettingsActions.Row] = [
            .init(id: "ME", name: "Halo", lastSeen: nil, isCurrent: true),
            .init(id: "A", name: "A", lastSeen: nil, isCurrent: false),
            .init(id: "B", name: "B", lastSeen: nil, isCurrent: false),
        ]
    }

    private func model(_ calls: Calls, canSignOut: Bool = true) -> DevicesSettingsModel {
        DevicesSettingsModel(actions: .init(
            load: { calls.rows }, canSignOut: { canSignOut },
            signOut: { ids, _ in
                calls.signedOut.append(ids)
                if calls.result == nil { calls.rows.removeAll { ids.contains($0.id) } }
                return calls.result
            }))
    }

    @Test("signing out the others removes them and never lists this device among them")
    func signsOutOthers() async {
        let calls = Calls()
        let model = model(calls)
        await model.load()
        #expect(model.canSignOut && model.others.map(\.id) == ["A", "B"])
        await model.confirmSignOut(model.others.map(\.id), password: "pw")
        #expect(calls.signedOut == [["A", "B"]] && model.rows.map(\.id) == ["ME"] && model.error == nil)
    }

    @Test("a wrong password asks again and keeps the sessions; an empty password asks nothing")
    func wrongPassword() async {
        let calls = Calls()
        calls.result = .wrongPassword
        let model = model(calls)
        await model.load()
        await model.confirmSignOut([], password: "pw")
        await model.confirmSignOut(["A"], password: "")
        #expect(calls.signedOut.isEmpty)
        await model.confirmSignOut(["A"], password: "wrong")
        #expect(model.pendingSignOut == ["A"] && model.error != nil && model.rows.count == 3)
    }

    @Test("an account page account (OIDC) offers no sign-out here")
    func oidc() async {
        let calls = Calls()
        let model = model(calls, canSignOut: false)
        await model.load()
        #expect(!model.canSignOut)
    }
}
