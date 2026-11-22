import Foundation
import HaloFoundation
import Testing
@testable import HaloDomain

@Suite("ShareTarget ordering")
struct ShareTargetTests {
    private func target(_ id: String, _ name: String, fav: Bool = false, at seconds: Double? = nil) -> ShareTarget {
        ShareTarget(id: try! RoomID(id), name: name, isDirect: false, isFavourite: fav, lastActivity: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    @Test("favourites first, then newest activity, then name; rooms without activity last")
    func order() {
        let ordered = ShareTarget.ordered([
            target("!a:x", "Zed", at: 10), target("!b:x", "Quiet"), target("!c:x", "Fav", fav: true, at: 1),
            target("!d:x", "Newer", at: 20), target("!e:x", "Alpha"),
        ])
        #expect(ordered.map(\.name) == ["Fav", "Newer", "Zed", "Alpha", "Quiet"])
    }
}
