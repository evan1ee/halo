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
}
