import Foundation
import HaloFoundation
import Testing
@testable import HaloDomain

@Suite("Stickers")
struct StickerTests {
    private let room = try! RoomID("!pack:x.org")
    private var ref: PackRef { PackRef(room: room, stateKey: "cats") }
    private func sticker(_ code: String, body: String? = nil, in pack: PackRef? = nil) -> Sticker {
        Sticker(pack: pack ?? ref, shortcode: code, body: body, url: "mxc://x.org/\(code)", info: nil)
    }
    private func pack(_ stickers: [Sticker], usage: Set<PackUsage> = [.sticker]) -> StickerPack {
        StickerPack(ref: ref, displayName: "Cats", avatarURL: nil, usage: usage, attribution: nil, stickers: stickers, source: .userEnabled)
    }

    // MARK: Parser

    @Test("a spec example parses: usage, names, images with info, sorted by shortcode")
    func parses() throws {
        let json = """
        {"images":{"wave":{"url":"mxc://x.org/w","body":"Waving","info":{"w":128,"h":64,"mimetype":"image/webp","size":1000}},
                   "alpha":{"url":"mxc://x.org/a"}},
         "pack":{"display_name":"Cats","avatar_url":"mxc://x.org/av","usage":["sticker"],"attribution":"me"}}
        """
        let pack = try #require(ImagePackParser.parse(Data(json.utf8), ref: ref, source: .room))
        #expect(pack.displayName == "Cats" && pack.avatarURL == "mxc://x.org/av" && pack.attribution == "me")
        #expect(pack.usage == [.sticker] && pack.offersStickers && pack.source == .room)
        #expect(pack.stickers.map(\.shortcode) == ["alpha", "wave"])
        #expect(pack.stickers[1].body == "Waving" && pack.stickers[1].info == StickerInfo(width: 128, height: 64, mimeType: "image/webp", size: 1000))
        #expect(pack.stickers[1].eventBody == "Waving" && pack.stickers[0].eventBody == "alpha")
    }

    @Test("missing usage means both; a missing name falls back to the state key; images without an mxc URL are dropped")
    func defaults() throws {
        let json = #"{"images":{"ok":{"url":"mxc://x.org/1"},"web":{"url":"https://x.org/1"},"none":{}}}"#
        let pack = try #require(ImagePackParser.parse(Data(json.utf8), ref: ref, source: .legacy))
        #expect(pack.usage == [.sticker, .emoticon] && pack.displayName == "cats")
        #expect(pack.stickers.map(\.shortcode) == ["ok"])
    }

    @Test("an emoticon-only pack doesn't offer stickers; malformed input gives nil; a bad shortcode is kept and flagged")
    func malformed() throws {
        let emoji = try #require(ImagePackParser.parse(Data(#"{"images":{},"pack":{"usage":["emoticon"]}}"#.utf8), ref: ref, source: .room))
        #expect(!emoji.offersStickers)
        for bad in ["", "[]", "not json", #"{"images":[1]}"#, #"{"pack":{}}"#] { #expect(ImagePackParser.parse(Data(bad.utf8), ref: ref, source: .room) == nil) }
        let odd = try #require(ImagePackParser.parse(Data(#"{"images":{"has space":{"url":"mxc://x.org/1"}}}"#.utf8), ref: ref, source: .room))
        #expect(odd.stickers.map(\.hasValidShortcode) == [false])
    }

    // MARK: Shortcodes

    @Test("the shortcode grammar", arguments: [("a", true), ("A-b_9", true), (String(repeating: "a", count: 100), true), (String(repeating: "a", count: 101), false), ("", false), ("a b", false), ("é", false), ("a.b", false)])
    func grammar(code: String, valid: Bool) { #expect(ShortcodeRules.isValid(code) == valid) }

    @Test("shortcodes made from file names always match the grammar (AC-S5) and can be made unique")
    func generation() {
        #expect(ShortcodeRules.make(fromFilename: "Happy Cat!!.png") == "Happy_Cat")
        #expect(ShortcodeRules.make(fromFilename: "日本語.webp") == "sticker")
        #expect(ShortcodeRules.make(fromFilename: ".hidden") == "hidden")
        var rng = SeededRandomNumberGenerator(seed: 5)
        let alphabet = Array("abcXYZ019 _-.!é日/\\\n")
        for _ in 0..<2000 {
            let name = String((0..<Int.random(in: 0...140, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            #expect(ShortcodeRules.isValid(ShortcodeRules.make(fromFilename: name)), "\(name.debugDescription)")
        }
        #expect(ShortcodeRules.unique("cat", avoiding: []) == "cat")
        #expect(ShortcodeRules.unique("cat", avoiding: ["cat", "cat-2"]) == "cat-3")
        let long = String(repeating: "a", count: 100)
        let made = ShortcodeRules.unique(long, avoiding: [long])
        #expect(ShortcodeRules.isValid(made) && made != long)
    }

    // MARK: Prefs

    @Test("favourites toggle; recents are newest first, de-duplicated, and capped at 30")
    func prefs() {
        var prefs = StickerPrefs()
        let a = sticker("a").ref
        prefs.toggleFavourite(a)
        #expect(prefs.isFavourite(a))
        prefs.toggleFavourite(a)
        #expect(!prefs.isFavourite(a))
        for n in 0..<40 { prefs.recordUse(sticker("s\(n)").ref, at: Date(timeIntervalSince1970: Double(n))) }
        prefs.recordUse(sticker("s5").ref, at: Date(timeIntervalSince1970: 100))
        #expect(prefs.recents.count == 30 && prefs.recents.first?.sticker.shortcode == "s5")
        #expect(prefs.recents.filter { $0.sticker.shortcode == "s5" }.count == 1)
    }

    @Test("merging two devices' prefs is a union for favourites and newest-use for recents, idempotent and order-independent for recents")
    func merging() {
        var one = StickerPrefs(), two = StickerPrefs()
        one.toggleFavourite(sticker("a").ref)
        two.toggleFavourite(sticker("b").ref)
        two.toggleFavourite(sticker("a").ref)
        one.recordUse(sticker("x").ref, at: Date(timeIntervalSince1970: 10))
        two.recordUse(sticker("x").ref, at: Date(timeIntervalSince1970: 20))
        two.recordUse(sticker("y").ref, at: Date(timeIntervalSince1970: 5))
        let merged = one.merged(with: two)
        #expect(merged.favourites.map(\.shortcode) == ["a", "b"])
        #expect(merged.recents.map(\.sticker.shortcode) == ["x", "y"] && merged.recents[0].usedAt == 20_000)
        #expect(merged.recents == two.merged(with: one).recents)
        #expect(merged.merged(with: merged) == merged)
    }

    @Test("the account-data form round-trips, skips junk entries, and refuses a newer version")
    func accountData() throws {
        var prefs = StickerPrefs()
        prefs.toggleFavourite(sticker("a").ref)
        prefs.recordUse(sticker("b").ref, at: Date(timeIntervalSince1970: 7))
        #expect(StickerPrefs.fromAccountData(prefs.accountData()) == prefs)
        let junk = #"{"version":1,"favourites":[{"room":"nope","pack":"p","shortcode":"s"},{"room":"!r:x.org","pack":"p","shortcode":"s"},{"room":"!r:x.org","pack":"p","shortcode":"s"}],"recents":[{"room":"!r:x.org","pack":"p","shortcode":"s"}]}"#
        let parsed = try #require(StickerPrefs.fromAccountData(Data(junk.utf8)))
        #expect(parsed.favourites.count == 1 && parsed.recents.isEmpty)
        #expect(StickerPrefs.fromAccountData(Data(#"{"version":2}"#.utf8)) == nil)
        #expect(StickerPrefs.fromAccountData(Data("[]".utf8)) == nil)
    }

    // MARK: Search

    @Test("search ranks favourites, then recents, then the rest; prefix before substring; blank finds nothing; emoticon-only packs are skipped")
    func search() {
        let cats = pack([sticker("cat_wave"), sticker("big_cat"), sticker("catnap"), sticker("dog")])
        let emoji = StickerPack(ref: PackRef(room: room, stateKey: "e"), displayName: "E", avatarURL: nil, usage: [.emoticon], attribution: nil, stickers: [sticker("cat_face", in: PackRef(room: room, stateKey: "e"))], source: .userEnabled)
        var prefs = StickerPrefs()
        #expect(StickerSearch.search("cat", in: [cats, emoji], prefs: prefs).map(\.shortcode) == ["cat_wave", "catnap", "big_cat"])
        prefs.recordUse(sticker("big_cat").ref, at: Date(timeIntervalSince1970: 1))
        prefs.toggleFavourite(sticker("catnap").ref)
        #expect(StickerSearch.search("CAT", in: [cats, emoji], prefs: prefs).map(\.shortcode) == ["catnap", "big_cat", "cat_wave"])
        #expect(StickerSearch.search("  ", in: [cats], prefs: prefs).isEmpty)
        #expect(StickerSearch.search("zzz", in: [cats], prefs: prefs).isEmpty)
    }

    @Test("search also matches the body")
    func searchBody() {
        let p = pack([sticker("x1", body: "Happy dance"), sticker("x2", body: "Sad")])
        #expect(StickerSearch.search("dance", in: [p], prefs: StickerPrefs()).map(\.shortcode) == ["x1"])
    }
}

@Suite("Pack creation")
struct PackCreationTests {
    private let room = try! RoomID("!pack:x.org")
    private func image(_ code: String) -> NewStickerImage { NewStickerImage(data: Data([1, 2, 3]), mimeType: "image/png", width: 512, height: 256, shortcode: code) }

    @Test("validation names the problem")
    func validation() {
        #expect(throws: HaloError.invalidInput("EMPTY_PACK_NAME")) { try ImagePackBuilder.validate(name: "  ", shortcodes: ["a"]) }
        #expect(throws: HaloError.invalidInput("NO_IMAGES")) { try ImagePackBuilder.validate(name: "Cats", shortcodes: []) }
        #expect(throws: HaloError.invalidInput("BAD_SHORTCODE")) { try ImagePackBuilder.validate(name: "Cats", shortcodes: ["a b"]) }
        #expect(throws: HaloError.invalidInput("DUPLICATE_SHORTCODE")) { try ImagePackBuilder.validate(name: "Cats", shortcodes: ["a", "a"]) }
        #expect(throws: HaloError.invalidInput("TOO_MANY_IMAGES")) { try ImagePackBuilder.validate(name: "Cats", shortcodes: (0...120).map { "s\($0)" }) }
        #expect(throws: Never.self) { try ImagePackBuilder.validate(name: "Cats", shortcodes: (0..<120).map { "s\($0)" }) }
    }

    @Test("the built content parses back to the same pack (round trip through ImagePackParser)")
    func roundTrip() throws {
        let content = ImagePackBuilder.content(name: " Cats ", uploaded: [(image("wave"), "mxc://x.org/1"), (image("dance"), "mxc://x.org/2")])
        let ref = PackRef(room: room, stateKey: ImagePackBuilder.stateKey)
        let pack = try #require(ImagePackParser.parse(content, ref: ref, source: .userEnabled))
        #expect(pack.displayName == "Cats" && pack.usage == [.sticker] && pack.offersStickers)
        #expect(pack.stickers.map(\.shortcode) == ["dance", "wave"])
        let wave = try #require(pack.stickers.last)
        #expect(wave.url == "mxc://x.org/1" && wave.info == StickerInfo(width: 512, height: 256, mimeType: "image/png", size: 3) && wave.hasValidShortcode)
        #expect(ImagePackBuilder.roomName(for: "Cats") == "Sticker pack: Cats")
    }

    @Test("enabling a pack keeps other packs and unknown properties, and is idempotent")
    func enabling() {
        let ref = PackRef(room: room, stateKey: "pack")
        let existing: [String: Any] = ["rooms": ["!other:x.org": ["p": ["note": 1]]], "extra": "keep"]
        let once = PackRegistry.enabling(ref, in: existing)
        #expect(once["extra"] as? String == "keep")
        let rooms = once["rooms"] as? [String: Any]
        #expect(((rooms?["!other:x.org"] as? [String: Any])?["p"] as? [String: Any])?["note"] as? Int == 1)
        #expect((rooms?[room.rawValue] as? [String: Any])?["pack"] != nil)
        #expect(NSDictionary(dictionary: PackRegistry.enabling(ref, in: once)).isEqual(to: once))
        #expect((PackRegistry.enabling(ref, in: nil)["rooms"] as? [String: Any])?.count == 1)
    }

    @Test("the pack-room list gets each room once, keeps unknown keys, and refuses a newer version")
    func packRooms() throws {
        let one = try #require(PackRegistry.recordingPackRoom(room, in: nil))
        #expect(one["rooms"] as? [String] == [room.rawValue] && one["version"] as? Int == 1)
        let again = try #require(PackRegistry.recordingPackRoom(room, in: one.merging(["x": true]) { $1 }))
        #expect(again["rooms"] as? [String] == [room.rawValue] && again["x"] as? Bool == true)
        #expect(PackRegistry.recordingPackRoom(room, in: ["version": 2]) == nil)
    }
}
