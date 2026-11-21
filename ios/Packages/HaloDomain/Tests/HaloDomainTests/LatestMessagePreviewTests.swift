import HaloDomain
import HaloFoundation
import Testing

@Suite("LatestMessagePreview")
struct LatestMessagePreviewTests {
    @Test("own messages say You, direct chats show the bare text, groups name the sender")
    func lines() {
        #expect(LatestMessagePreview(text: "hi", senderName: "Ann", isOwn: true).line(isDirect: true) == "You: hi")
        #expect(LatestMessagePreview(text: "hi", senderName: "Ann", isOwn: false).line(isDirect: true) == "hi")
        #expect(LatestMessagePreview(text: "hi", senderName: "Ann", isOwn: false).line(isDirect: false) == "Ann: hi")
        #expect(LatestMessagePreview(text: "hi", senderName: nil, isOwn: false).line(isDirect: false) == "hi")
        #expect(LatestMessagePreview(text: "hi", senderName: "", isOwn: false).line(isDirect: false) == "hi")
    }

    @Test("allowlisted bot cards show a concise summary; non-allowlisted senders keep plain text (ROOM_LIST FR-3)")
    func botCardPreviews() throws {
        let bot = try UserID("@bot:x.org")
        let allowlist: Set<String> = [bot.rawValue]

        let todoHTML = "📋 <b>Work:</b><br/>• [<b>#1</b>] Ship<br/>• [<b>#2</b>] <del>Plan</del> ✅"
        let todo = LatestMessagePreview(text: "📋 Work:", senderName: "TodoBot", isOwn: false, senderID: bot, formattedBody: todoHTML)
        #expect(todo.line(isDirect: false, botSenders: allowlist) == "TodoBot: Work · 1 open")
        #expect(todo.line(isDirect: true, botSenders: allowlist) == "Work · 1 open")
        #expect(todo.line(isDirect: false, botSenders: []) == "TodoBot: 📋 Work:")

        let allDoneHTML = "📋 <b>Work:</b><br/>• [<b>#1</b>] <del>Ship</del> ✅"
        let allDone = LatestMessagePreview(text: "📋 Work:", senderName: "TodoBot", isOwn: false, senderID: bot, formattedBody: allDoneHTML)
        #expect(allDone.line(isDirect: true, botSenders: allowlist) == "Work · all done")

        let added = LatestMessagePreview(
            text: "Added Task #7", senderName: "TodoBot", isOwn: false, senderID: bot,
            formattedBody: "Added Task <b>#7</b> for Ann: <i>\"Buy milk\"</i>")
        #expect(added.line(isDirect: true, botSenders: allowlist) == "Task #7: Buy milk")

        let reminder = LatestMessagePreview(
            text: "Reminder", senderName: "TodoBot", isOwn: false, senderID: bot,
            formattedBody: "⏰ <b>Reminder #3 set!</b> at 09:00 for: <i>\"Standup\"</i>")
        #expect(reminder.line(isDirect: true, botSenders: allowlist) == "Reminder #3 (at 09:00): Standup")

        let done = LatestMessagePreview(
            text: "Marked done", senderName: "TodoBot", isOwn: false, senderID: bot,
            formattedBody: "✅ Marked task as done: <i>\"Buy milk\"</i>")
        #expect(done.line(isDirect: true, botSenders: allowlist) == "Done: Buy milk")

        let deleted = LatestMessagePreview(
            text: "Deleted", senderName: "TodoBot", isOwn: false, senderID: bot,
            formattedBody: "🗑️ Deleted task: <i>\"Old\"</i>")
        #expect(deleted.line(isDirect: true, botSenders: allowlist) == "Deleted: Old")
    }
}
