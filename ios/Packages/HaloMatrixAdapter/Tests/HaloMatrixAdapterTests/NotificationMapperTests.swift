import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

@Suite("NotificationMapper")
struct NotificationMapperTests {
    @Test("a direct chat shows the sender as the title, a group the room with the sender in the body")
    func shaping() {
        #expect(NotificationMapper.shape(sender: "Alice", room: "Team", isDirect: true, text: "hi") == NotificationDisplay(title: "Alice", body: "hi"))
        #expect(NotificationMapper.shape(sender: "Alice", room: "Team", isDirect: false, text: "hi") == NotificationDisplay(title: "Team", body: "Alice: hi"))
    }

    @Test("message types become short, content-free labels except for text-like bodies")
    func text() {
        #expect(NotificationMapper.text(of: .text(content: TextMessageContent(body: "hello", formatted: nil))) == "hello")
        #expect(NotificationMapper.text(of: .other(msgtype: "m.custom", body: "x")) == "x")
    }

    @Test("a missing event is not found; filtered and redacted events are suppressed")
    func statuses() throws {
        #expect(throws: HaloError.notFound) { try NotificationMapper.result(.eventNotFound) }
        #expect(try NotificationMapper.result(.eventFilteredOut) == .suppressed)
        #expect(try NotificationMapper.result(.eventRedacted) == .suppressed)
    }

    @Test("R-02: rawEventTimestamp extracts origin_server_ts from undecryptable and invite event JSON")
    func rawEventTimestamp() {
        let encrypted = #"{"type":"m.room.encrypted","origin_server_ts":1700000000500,"content":{}}"#
        #expect(NotificationMapper.rawEventTimestamp(encrypted) == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(NotificationMapper.rawEventTimestamp(#"{"type":"m.room.encrypted"}"#) == nil)
        #expect(NotificationMapper.rawEventTimestamp("not json") == nil)
    }
}
