import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("BotAllowlist")
struct BotAllowlistTests {
    @Test("round-trips through account-data JSON and preserves unique order")
    func roundTrip() throws {
        let a = try UserID("@todo:x.org"), b = try UserID("@ops:x.org")
        let list = BotAllowlist(bots: [a, b, a])
        #expect(list.bots == [a, b])
        let data = list.accountData()
        #expect(BotAllowlist.fromAccountData(data) == list)
    }

    @Test("malformed entries are skipped; corrupt JSON or a newer version returns nil")
    func validationAndVersioning() throws {
        let valid = Data(#"{"version":1,"bots":["@bot:x.org","not-a-user","@bot:x.org"]}"#.utf8)
        #expect(BotAllowlist.fromAccountData(valid) == BotAllowlist(bots: [try UserID("@bot:x.org")]))

        let newer = Data(#"{"version":2,"bots":["@bot:x.org"]}"#.utf8)
        #expect(BotAllowlist.fromAccountData(newer) == nil)

        #expect(BotAllowlist.fromAccountData(Data("not json".utf8)) == nil)
        #expect(BotAllowlist.fromAccountData(Data("[]".utf8)) == nil)
    }

    @Test("an edit changes only what it changed: entries the editor didn't know stay, unknown keys stay (D120)")
    func applyingAnEdit() throws {
        let a = try UserID("@a:x.org"), b = try UserID("@b:x.org"), c = try UserID("@c:x.org")
        func list(_ bots: UserID...) -> BotAllowlist { BotAllowlist(bots: bots) }
        // The editor hadn't loaded the list yet.
        #expect(list(a, b).applying(from: list(), to: list(c)) == list(a, b, c))
        // Another device added b meanwhile.
        #expect(list(a, b).applying(from: list(a), to: list(a, c)) == list(a, b, c))
        #expect(list(a, b).applying(from: list(a), to: list()) == list(b))
        // Another device removed a meanwhile: editing something else doesn't bring it back.
        #expect(list(b).applying(from: list(a, b), to: list(a, b, c)) == list(b, c))
        // Same list: the editor's order is kept. Repeating an edit changes nothing.
        #expect(list(a, b).applying(from: list(a, b), to: list(b, a)) == list(b, a))
        #expect(list(a, c).applying(from: list(a), to: list(a, c)) == list(a, c))
        let content = list(a).content(replacing: ["other": 1, "bots": ["@old:x.org"]])
        #expect(content["other"] as? Int == 1 && content["bots"] as? [String] == ["@a:x.org"] && content["version"] as? Int == 1)
        #expect(BotAllowlist.fromContent(content) == list(a) && BotAllowlist.fromContent(["version": 2]) == nil)
    }
}
