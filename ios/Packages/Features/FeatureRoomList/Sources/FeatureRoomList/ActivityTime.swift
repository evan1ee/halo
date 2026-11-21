import Foundation

/// The short time shown at the right of a room row, the way Messages does it:
/// today the time, then "Yesterday", then the weekday for the past week,
/// then the day and month this year, and the full date before that.
public enum ActivityTime {
    public static func text(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < startOfToday {
            return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
        }
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style.day().month(.abbreviated))
        }
        return date.formatted(style.day().month(.abbreviated).year())
    }
}
