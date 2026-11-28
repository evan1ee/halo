import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureTimeline

/// Unit tests for the child models extracted from `TimelineViewModel` (audit F-08).
@MainActor
@Suite("TimelineViewModel child models (audit F-08)")
struct TimelineChildModelsTests {
    @Test("TimelineComposerModel handles edit stash/restore, mention picking, and restored draft without firing edit callback")
    func composerStandaloneBehaviour() throws {
        let composer = TimelineComposerModel()
        var editedCalls: [(String, Bool)] = []
        composer.onDraftEdited = { editedCalls.append(($0, $1)) }

        composer.applyRestoredDraft("Saved draft")
        #expect(composer.draft == "Saved draft")
        #expect(editedCalls.isEmpty, "restoring a draft must not trigger typing or re-save")

        let row = TimelineRow(
            id: "r1", style: .ownMessage, sender: "Me", text: "Original (edited)",
            eventID: try EventID("$e1:x.org"), isOwn: true,
            source: .init(sender: "@me:x.org", eventID: "$e1:x.org", body: "Original", formattedBody: nil)
        )
        composer.beginEdit(row)
        #expect(composer.editing == row.eventID)
        #expect(composer.draft == "Original")
        #expect(editedCalls.isEmpty, "starting edit must not trigger draft save")

        composer.cancelEdit()
        #expect(composer.editing == nil)
        #expect(composer.draft == "Saved draft")

        let alice = RoomMember(user: try UserID("@alice:x.org"), displayName: "Alice")
        composer.members = [alice]
        composer.draft = "Hi @al"
        #expect(composer.mentionQuery == "al")
        #expect(composer.mentionSuggestions == [alice])
        composer.pickMention(alice)
        #expect(composer.draft == "Hi @Alice ")
        #expect(composer.pendingMentions.map(\.user) == [alice.user])
    }

    @Test("TimelineBotTaskModel tracks task state, sends one 👍 on source event, and clears timeouts on completion")
    func botTaskModelStandaloneBehaviour() async throws {
        let botState = TimelineBotTaskModel()
        let botID = try UserID("@bot:x.org")
        let sourceID = try EventID("$src1:x.org")
        let doneID = try EventID("$done1:x.org")
        botState.botSenders = [botID.rawValue]

        let created = TimelineItem(id: TimelineItemID("1"), content: .event(TimelineEvent(
            eventID: sourceID,
            sender: botID,
            senderName: "TodoBot",
            timestamp: Date(timeIntervalSince1970: 100),
            isOwn: false,
            kind: .text("Added Task #1", isEdited: false),
            formattedBody: "Added Task <b>#1</b> for Ann: <i>\"Ship release\"</i>"
        )))
        botState.update(items: [created], room: nil, isFocused: false)
        #expect(botState.rowState(bot: botID.rawValue, id: "1") == .open)

        var reacted: [(EventID, String)] = []
        await botState.tick(
            bot: botID.rawValue,
            id: "1",
            rows: [],
            toggleReaction: { reacted.append(($0, $1)) },
            onError: { Issue.record("unexpected error: \($0)") }
        )
        let first = try #require(reacted.first)
        #expect(reacted.count == 1)
        #expect(first.0 == sourceID && first.1 == "👍")
        #expect(botState.rowState(bot: botID.rawValue, id: "1") == .pending)
        #expect(!botState.timeouts.isEmpty)

        // Completion cancels timeout and flips row to .completed.
        let completed = TimelineItem(id: TimelineItemID("2"), content: .event(TimelineEvent(
            eventID: doneID,
            sender: botID,
            senderName: "TodoBot",
            timestamp: Date(timeIntervalSince1970: 120),
            isOwn: false,
            kind: .text("Completed Task #1", isEdited: false),
            formattedBody: "📋 <b>T:</b><br/>• [<b>#1</b>] <del>Ship release</del> ✅<br/>"
        )))
        botState.update(items: [created, completed], room: nil, isFocused: false)
        #expect(botState.rowState(bot: botID.rawValue, id: "1") == .completed)
        #expect(botState.timeouts.isEmpty)
    }

    @Test("TimelineMediaModel gates hidden previews and reveals per MediaRef")
    func mediaModelPreviewGating() {
        let mediaState = TimelineMediaModel()
        let img = TimelineRow.Image(ref: MediaRef(token: "mxc://x.org/img1"), aspectRatio: 1.5)
        let vid = TimelineRow.Video(
            ref: MediaRef(token: "mxc://x.org/vid1"),
            filename: "clip.mp4",
            caption: nil,
            mimeType: "video/mp4",
            size: 1024,
            duration: 5,
            aspectRatio: 16.0 / 9.0,
            thumbnail: nil,
            blurhash: nil,
            isOwn: false
        )
        #expect(mediaState.showsPreview(of: img))
        #expect(mediaState.showsPreview(of: vid))

        mediaState.previewsHidden = true
        #expect(!mediaState.showsPreview(of: img))
        #expect(!mediaState.showsPreview(of: vid))

        mediaState.revealPreview(of: img)
        #expect(mediaState.showsPreview(of: img))
        #expect(!mediaState.showsPreview(of: vid))

        mediaState.revealPreview(of: vid)
        #expect(mediaState.showsPreview(of: vid))
    }
}
