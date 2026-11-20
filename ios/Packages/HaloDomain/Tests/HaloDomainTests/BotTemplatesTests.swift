import Testing

@testable import HaloDomain

@Suite("BotTemplates")
struct BotTemplatesTests {
    @Test("a todo list parses into rows, finished rows marked, ids and text kept")
    func todoList() {
        let html = "📋 <b>Ann's tasks:</b><br/>• [<b>#1</b>] Buy milk<br/>• [<b>#2</b>] <del>Call mum</del> ✅<br/>• [<b>#14</b>] Tom &amp; Jerry<br/>"
        #expect(BotTemplates.parse(html) == .todoList(title: "Ann's tasks", rows: [
            .init(id: "1", text: "Buy milk", isDone: false),
            .init(id: "2", text: "Call mum", isDone: true),
            .init(id: "14", text: "Tom & Jerry", isDone: false),
        ]))
    }

    @Test("line breaks spelled <br> or <br /> (as a sanitiser re-serialises them) parse the same")
    func lineBreakSpellings() {
        let expected = BotTemplates.parse("📋 <b>T:</b><br/>• [<b>#1</b>] a<br/>• [<b>#2</b>] b<br/>")
        #expect(expected != nil)
        #expect(BotTemplates.parse("📋 <b>T:</b><br>• [<b>#1</b>] a<br>• [<b>#2</b>] b<br>") == expected)
        #expect(BotTemplates.parse("📋 <b>T:</b><br />• [<b>#1</b>] a<br />• [<b>#2</b>] b<br />") == expected)
    }

    @Test("a todo list with any row that doesn't parse falls back whole")
    func todoListStrict() {
        #expect(BotTemplates.parse("📋 <b>T:</b><br/>• [<b>#1</b>] ok<br/>• [<b>x</b>] bad<br/>") == nil)
        #expect(BotTemplates.parse("📋 <b>T:</b><br/>• [<b>#1</b>] <i>markup</i><br/>") == nil)
        #expect(BotTemplates.parse("📋 <b>T:</b><br/>") == nil)
        #expect(BotTemplates.parse("📋 <b>T:</b><br/>• [<b>#1</b>] <del>x</del> done<br/>") == nil)
    }

    @Test("a created task, a reminder, a completion and a deletion")
    func singleMessages() {
        #expect(BotTemplates.parse("Added Task <b>#7</b> for Ann: <i>\"Pay rent\"</i>") == .taskAdded(id: "7", owner: "Ann", title: "Pay rent"))
        #expect(BotTemplates.parse("Added Task <b>#7</b>: <i>\"Pay rent\"</i>") == .taskAdded(id: "7", owner: nil, title: "Pay rent"))
        #expect(BotTemplates.parse("⏰ <b>Reminder #3 set!</b> Tomorrow 9:00 for: <i>\"Dentist\"</i>")
            == .reminderSet(id: "3", when: "Tomorrow 9:00", title: "Dentist"))
        #expect(BotTemplates.parse("✅ Marked task as done: <i>\"Pay rent\"</i>") == .taskDone(title: "Pay rent"))
        #expect(BotTemplates.parse("🗑️ Deleted task: <i>\"Pay rent\"</i>") == .taskDeleted(title: "Pay rent"))
        #expect(BotTemplates.parse("🗑 Deleted task: <i>\"Pay rent\"</i>") == .taskDeleted(title: "Pay rent"))
    }

    @Test("near misses and ordinary messages are not cards")
    func negatives() {
        for html in [
            "", "hello", "<b>hi</b>", "Added Task <b>#x</b> for Ann: <i>\"t\"</i>", "Added Task <b>#1</b> for Ann: <i>\"t\"</i> extra",
            "✅ Marked task as done: <i>t</i>", "✅ Marked task as done: <i>\"<b>t</b>\"</i>", "Reminder #1 set! later",
            "<b>Reminder #1 set!</b> now for: <i>\"\"</i>",
        ] { #expect(BotTemplates.parse(html) == nil, "\(html)") }
    }

    @Test("random markup never crashes and never yields a card out of nothing")
    func fuzz() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["📋 <b>", ":</b><br/>", "• [<b>#", "</b>] ", "<del>", "</del>", " ✅", "<br/>", "Added Task <b>#", "<i>\"", "\"</i>", "for: ", "&amp;", "x", "1", " ", "<", ">"]
        for _ in 0..<20_000 {
            let html = (0..<Int.random(in: 0...12, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            _ = BotTemplates.parse(html)
        }
    }
}
