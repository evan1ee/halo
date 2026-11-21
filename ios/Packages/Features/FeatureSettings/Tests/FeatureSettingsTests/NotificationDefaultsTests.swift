import Foundation
import Testing

@testable import FeatureSettings

@MainActor
@Suite("NotificationDefaultsModel")
struct NotificationDefaultsTests {
    final class Store: @unchecked Sendable {  // test double touched from one test at a time
        var values: [NotificationDefaultTarget: NotificationDefaultChoice] = [.directChats: .allMessages]
        var mentions: [NotificationMentionTarget: Bool] = [.user: true]
        var failing = false
    }

    func model(_ store: Store) -> NotificationDefaultsModel {
        NotificationDefaultsModel(actions: .init(
            load: { store.values[$0] },
            save: { target, choice in
                if store.failing { return false }
                store.values[target] = choice
                return true
            },
            loadMention: { store.mentions[$0] },
            saveMention: { target, value in
                if store.failing { return false }
                store.mentions[target] = value
                return true
            }))
    }

    @Test("loads what the server has; an unreadable or custom default stays unset; changes save, failures keep the old choice")
    func flow() async {
        let store = Store()
        let model = model(store)
        await model.load()
        #expect(model.loaded && model.choices[.directChats] == .allMessages && model.choices[.groupChats] == nil)
        await model.set(.groupChats, to: .mentionsAndKeywords)
        #expect(model.choices[.groupChats] == .mentionsAndKeywords && store.values[.groupChats] == .mentionsAndKeywords)
        store.failing = true
        await model.set(.directChats, to: .mentionsAndKeywords)
        #expect(model.choices[.directChats] == .allMessages && model.error != nil)
        store.failing = false
        await model.set(.directChats, to: .mentionsAndKeywords)
        #expect(model.choices[.directChats] == .mentionsAndKeywords && model.error == nil)
    }

    @Test("mention rules load, switch, and keep the old value on failure; an unreadable one stays unset")
    func mentions() async {
        let store = Store()
        let model = model(store)
        await model.load()
        #expect(model.mentions[.user] == true && model.mentions[.room] == nil)
        await model.setMention(.user, enabled: false)
        #expect(model.mentions[.user] == false && store.mentions[.user] == false)
        store.failing = true
        await model.setMention(.user, enabled: true)
        #expect(model.mentions[.user] == false && model.error != nil)
    }
}
