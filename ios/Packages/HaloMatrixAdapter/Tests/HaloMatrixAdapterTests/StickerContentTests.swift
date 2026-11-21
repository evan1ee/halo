import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

@Suite("m.sticker content")
struct StickerContentTests {
    private func object(_ sticker: Sticker) throws -> [String: Any] {
        let json = try MatrixTimelineSession.stickerContent(sticker)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test("a sticker without pack details still carries an empty info object (Ruma rejects one without it)")
    func bareStickerHasInfo() throws {
        let pack = PackRef(room: try RoomID("!p:x.org"), stateKey: "cats")
        let bare = try object(Sticker(pack: pack, shortcode: "dance", body: nil, url: "mxc://x.org/a", info: nil))
        #expect(bare["body"] as? String == "dance" && bare["url"] as? String == "mxc://x.org/a")
        #expect((bare["info"] as? [String: Any])?.isEmpty == true)
        let full = try object(Sticker(pack: pack, shortcode: "wave", body: "Waving", url: "mxc://x.org/b", info: StickerInfo(width: 128, height: 96, mimeType: "image/png", size: 70)))
        let info = try #require(full["info"] as? [String: Any])
        #expect(info["w"] as? Int == 128 && info["h"] as? Int == 96 && info["mimetype"] as? String == "image/png" && info["size"] as? Int == 70)
    }

    @Test("a sticker the SDK can't parse maps to a sticker without a picture, other unparsable events stay unsupported")
    func unparsableSticker() {
        #expect(TimelineMapper.kind(of: .failedToParseMessageLike(eventType: "m.sticker", error: "missing field `info`")) == .sticker(body: "", source: nil))
        #expect(TimelineMapper.kind(of: .failedToParseMessageLike(eventType: "m.room.message", error: "x")) == .unsupported)
    }
}
