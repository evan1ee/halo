import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloMatrixAdapter

@Suite("SearchMapper")
struct SearchMapperTests {
    private func answer(_ json: String) throws -> SearchMapper.ServerAnswer {
        SearchMapper.recheck(try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]))
    }

    @Test("a shown message as the server has it now: the same, deleted, edited, edited by someone else, encrypted")
    func recheck() throws {
        #expect(try answer(#"{"type":"m.room.message","sender":"@a:x","content":{"body":"x","msgtype":"m.text"}}"#) == .result(.unchanged))
        #expect(try answer(#"{"type":"m.room.message","sender":"@a:x","content":{},"unsigned":{"redacted_because":{}}}"#) == .result(.gone))
        #expect(try answer(#"{"type":"m.room.encrypted","sender":"@a:x","content":{}}"#) == .result(.gone))
        #expect(try answer(#"{"type":"m.room.encrypted","sender":"@a:x","content":{"ciphertext":"c"}}"#) == .result(.unchanged))
        let edit = #""content":{"body":"* new","msgtype":"m.text","m.new_content":{"body":"new","msgtype":"m.text"},"m.relates_to":{"rel_type":"m.replace","event_id":"$1"}}"#
        #expect(try answer(#"{"sender":"@a:x","content":{"body":"x"},"unsigned":{"m.relations":{"m.replace":{"type":"m.room.message","sender":"@a:x",\#(edit)}}}}"#)
            == .result(.edited(SearchableContent(kind: .message, body: "new"))))
        #expect(try answer(#"{"sender":"@a:x","content":{"body":"x"},"unsigned":{"m.relations":{"m.replace":{"type":"m.room.message","sender":"@eve:x",\#(edit)}}}}"#) == .result(.unchanged))
        #expect(try answer(#"{"sender":"@a:x","content":{"ciphertext":"x"},"unsigned":{"m.relations":{"m.replace":{"type":"m.room.encrypted","sender":"@a:x","content":{"ciphertext":"y"}}}}}"#) == .encryptedEdit)
    }

    @Test("live image attachment JSON resolves a valid SDK MediaRef thumbnail token")
    func liveThumbnailRef() {
        let plain = MatrixMessageIndexSource.thumbnailRef(in: #"{"msgtype":"m.image","body":"The only way","url":"mxc://x.org/pic1","info":{"mimetype":"image/png","size":1400000}}"#)
        #expect(plain != nil)
        let doc = MatrixMessageIndexSource.thumbnailRef(in: #"{"msgtype":"m.file","body":"doc.pdf","url":"mxc://x.org/doc1"}"#)
        #expect(doc == nil, "a plain file without thumbnail_url uses its format icon tile")
    }

    @Test("clampedInt prevents trapping on out-of-range UInt64 sizes and dimensions")
    func clampedUnsignedIntegers() {
        #expect(SearchMapper.clampedInt(nil) == nil)
        #expect(SearchMapper.clampedInt(1_400_000) == 1_400_000)
        #expect(SearchMapper.clampedInt(UInt64.max) == Int.max)
        #expect(TimelineMapper.clampedInt(UInt64.max) == Int.max)
    }
}
