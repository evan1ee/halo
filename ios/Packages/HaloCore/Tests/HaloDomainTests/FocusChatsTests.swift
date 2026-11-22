import Testing
@testable import HaloDomain

@Suite("FocusChats")
struct FocusChatsTests {
    @Test("each Focus choice maps to the matching list filter and has a title")
    func mapping() {
        #expect(FocusChats.people.listFilter == .people)
        #expect(FocusChats.rooms.listFilter == .rooms)
        #expect(FocusChats.favourites.listFilter == .favourites)
        #expect(FocusChats.unread.listFilter == .unread)
        #expect(FocusChats.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
