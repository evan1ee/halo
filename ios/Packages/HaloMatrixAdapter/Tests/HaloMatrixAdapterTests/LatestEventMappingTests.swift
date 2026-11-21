import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

@Suite("RoomList latest event mapping")
struct LatestEventMappingTests {
    private func map(_ value: LatestEventValue) -> LatestEventRef? { MatrixRoomListPort.latestEvent(value) }

    @Test("a remote event keeps its time (milliseconds) and whether the user sent it")
    func remote() {
        let other = map(.remote(timestamp: 1_700_000_123_456, sender: "@b:x", isOwn: false, profile: .pending, content: .callInvite))
        #expect(other == LatestEventRef(timestamp: Date(timeIntervalSince1970: 1_700_000_123.456), senderIsSelf: false))
        let own = map(.remote(timestamp: 5_000, sender: "@a:x", isOwn: true, profile: .pending, content: .callInvite))
        #expect(own == LatestEventRef(timestamp: Date(timeIntervalSince1970: 5), senderIsSelf: true))
    }

    @Test("a local echo is the user's own event in every sending state")
    func local() {
        for state in [LatestEventValueLocalState.isSending, .hasBeenSent, .cannotBeSent] {
            let ref = map(.local(timestamp: 9_000, sender: "@a:x", profile: .pending, content: .callInvite, state: state))
            #expect(ref == LatestEventRef(timestamp: Date(timeIntervalSince1970: 9), senderIsSelf: true))
        }
    }

    @Test("rooms without events and invites have no latest event")
    func none() {
        #expect(map(.none) == nil)
        #expect(map(.remoteInvite(timestamp: 1_000, inviter: "@b:x", inviterProfile: .pending)) == nil)
    }

    private func message(_ type: MessageType, body: String = "ignored") -> TimelineItemContent {
        .msgLike(content: MsgLikeContent(
            kind: .message(content: MessageContent(msgType: type, body: body, isEdited: false, mentions: nil)),
            inReplyTo: nil, threadRoot: nil, threadSummary: nil))
    }

    @Test("a text message previews its first line; notices and emotes too; media shows a label")
    func previewText() {
        func text(_ body: String) -> MessageType { .text(content: TextMessageContent(body: body, formatted: nil)) }
        #expect(MatrixRoomListPort.previewText(message(text("hello\nsecond line"))) == "hello")
        #expect(MatrixRoomListPort.previewText(message(.notice(content: NoticeMessageContent(body: "done", formatted: nil)))) == "done")
        #expect(MatrixRoomListPort.previewText(message(.emote(content: EmoteMessageContent(body: "waves", formatted: nil)))) == "* waves")
        #expect(MatrixRoomListPort.previewText(message(.other(msgtype: "x.custom", body: "custom body"))) == "custom body")
        let redacted = TimelineItemContent.msgLike(content: MsgLikeContent(kind: .redacted, inReplyTo: nil, threadRoot: nil, threadSummary: nil))
        #expect(MatrixRoomListPort.previewText(redacted) == "Message deleted")
        #expect(MatrixRoomListPort.previewText(.callInvite) == nil)
        let source = try? MediaSource.fromUrl(url: "mxc://x.org/a")
        if let source {
            let sticker = TimelineItemContent.msgLike(content: MsgLikeContent(
                kind: .sticker(body: "Dancing", info: ImageInfo(height: nil, width: nil, mimetype: nil, size: nil, thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: nil), source: source),
                inReplyTo: nil, threadRoot: nil, threadSummary: nil))
            #expect(MatrixRoomListPort.previewText(sticker) == "Sticker: Dancing")
        }
    }

    @Test("the preview carries the sender's display name, user ID, HTML body and whether it is the user's own; invites and empty rooms have none")
    func previewSender() throws {
        let content = message(.text(content: TextMessageContent(body: "hi", formatted: nil)))
        let ready = ProfileDetails.ready(displayName: "Ann", displayNameAmbiguous: false, avatarUrl: nil, status: nil, call: nil)
        let annID = try UserID("@a:x")
        #expect(MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@a:x", isOwn: false, profile: ready, content: content)) == LatestMessagePreview(text: "hi", senderName: "Ann", isOwn: false, senderID: annID))
        #expect(MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@a:x", isOwn: false, profile: .pending, content: content))?.senderName == nil)
        #expect(MatrixRoomListPort.preview(.local(timestamp: 1, sender: "@a:x", profile: .pending, content: content, state: .isSending))?.isOwn == true)
        #expect(MatrixRoomListPort.preview(.none) == nil)
        let joined = TimelineItemContent.roomMembership(userId: "@a:x", userDisplayName: "Ann", change: .joined, reason: nil)
        #expect(MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@a:x", isOwn: false, profile: ready, content: joined)) == LatestMessagePreview(text: "Ann joined", senderName: nil, isOwn: false))
        #expect(MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@a:x", isOwn: true, profile: ready, content: joined))?.text == "You joined")
        let other = TimelineItemContent.roomMembership(userId: "@a:x", userDisplayName: "Ann", change: .notImplemented, reason: nil)
        #expect(MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@a:x", isOwn: false, profile: ready, content: other)) == nil)
        #expect(MatrixRoomListPort.preview(.remoteInvite(timestamp: 1, inviter: nil, inviterProfile: .pending)) == nil)

        // HTML formatted bodies are extracted on text, notice and emote events (for bots and styled text).
        let html = FormattedBody(format: .html, body: "<b>hi</b>")
        let notice = message(.notice(content: NoticeMessageContent(body: "hi", formatted: html)))
        let emote = message(.emote(content: EmoteMessageContent(body: "hi", formatted: html)))
        #expect(TimelineMapper.formattedHTML(of: notice) == "<b>hi</b>")
        #expect(TimelineMapper.formattedHTML(of: emote) == "<b>hi</b>")
        #expect(MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@bot:x", isOwn: false, profile: ready, content: notice)) == LatestMessagePreview(text: "hi", senderName: "Ann", isOwn: false, senderID: try UserID("@bot:x"), formattedBody: "<b>hi</b>"))

        // Reply and mention flags map from MsgLikeContent.inReplyTo and MessageContent.mentions.
        let replyWithMention = TimelineItemContent.msgLike(content: MsgLikeContent(
            kind: .message(content: MessageContent(
                msgType: .text(content: TextMessageContent(body: "ping", formatted: nil)),
                body: "ping", isEdited: false, mentions: Mentions(userIds: ["@me:x"], room: false))),
            inReplyTo: InReplyToDetails(noHandle: .init()), threadRoot: nil, threadSummary: nil))
        let mapped = MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@a:x", isOwn: false, profile: ready, content: replyWithMention), ownUserID: "@me:x")
        #expect(mapped?.isReply == true && mapped?.mentionsMe == true)
        let otherUser = MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@a:x", isOwn: false, profile: ready, content: replyWithMention), ownUserID: "@someoneelse:x")
        #expect(otherUser?.isReply == true && otherUser?.mentionsMe == false)
        let roomMention = TimelineItemContent.msgLike(content: MsgLikeContent(
            kind: .message(content: MessageContent(
                msgType: .text(content: TextMessageContent(body: "all", formatted: nil)),
                body: "all", isEdited: false, mentions: Mentions(userIds: [], room: true))),
            inReplyTo: nil, threadRoot: nil, threadSummary: nil))
        #expect(MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@a:x", isOwn: false, profile: ready, content: roomMention), ownUserID: "@me:x")?.mentionsMe == true)
        #expect(MatrixRoomListPort.preview(.remote(timestamp: 1, sender: "@me:x", isOwn: true, profile: ready, content: roomMention), ownUserID: "@me:x")?.mentionsMe == false)
    }
}
