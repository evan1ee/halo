import HaloDomain
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
}
