import Foundation
import Testing
@testable import FeatureRoomList

@Suite struct ActivityTimeTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    /// Saturday 21 November 2026, 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_255_200)

    private func ago(days: Double, hours: Double = 0) -> Date {
        now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
    }

    @Test func todayShowsTheTime() {
        let text = ActivityTime.text(ago(days: 0, hours: 1), now: now, calendar: calendar)
        #expect(text.hasPrefix("9:00"))
    }

    @Test func yesterdaySaysYesterday() {
        #expect(ActivityTime.text(ago(days: 1), now: now, calendar: calendar) == "Yesterday")
    }

    @Test func thisWeekShowsTheWeekday() {
        #expect(ActivityTime.text(ago(days: 3), now: now, calendar: calendar) == "Wednesday")
        #expect(ActivityTime.text(ago(days: 6), now: now, calendar: calendar) == "Sunday")
    }

    @Test func earlierThisYearShowsDayAndMonth() {
        #expect(ActivityTime.text(ago(days: 10), now: now, calendar: calendar) == "Nov 11")
    }

    @Test func earlierYearsShowTheYear() {
        #expect(ActivityTime.text(ago(days: 400), now: now, calendar: calendar) == "Oct 17, 2025")
    }
}
