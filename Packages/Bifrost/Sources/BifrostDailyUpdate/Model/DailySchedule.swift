import Foundation

// The reminder rules of the Daily update. The rules take a Date and a Calendar, so the local wall
// clock (the day of the week, the hour and the minute) decides, and a day with a time change
// needs no special case. A test pins both the Date and the Calendar.

// What happened today. The file keeps a send as milliseconds since 1970 (Stamps).
package struct DayMarks: Sendable, Equatable, Codable {
    // The local date, "YYYY-MM-DD".
    package var date: String
    package var skipped: Bool
    // The area ID to the time of the send.
    package var sent: [String: Date]
    package var firstShown: Bool
    package var secondShown: Bool

    package init(
        date: String, skipped: Bool = false, sent: [String: Date] = [:], firstShown: Bool = false,
        secondShown: Bool = false
    ) {
        self.date = date
        self.skipped = skipped
        self.sent = sent
        self.firstShown = firstShown
        self.secondShown = secondShown
    }

    // The marks of a day with nothing done.
    package static func fresh(_ date: String) -> DayMarks { DayMarks(date: date) }

    // The local date of a moment, "YYYY-MM-DD".
    package static func dateText(_ now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // True when each area that is on has a send, or the user skipped the day.
    package func allDone(_ areas: [WorkArea]) -> Bool {
        skipped || areas.filter(\.on).allSatisfy { sent[$0.id] != nil }
    }

    private enum Key: String, CodingKey {
        case date, skipped, sent, firstShown, secondShown
    }

    // A marks value with no date is not a marks value: the decode throws, and the state uses
    // fresh marks. A field of the wrong type gets its default.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        date = try container.decode(String.self, forKey: .date)
        skipped = (try? container.decode(Bool.self, forKey: .skipped)) ?? false
        firstShown = (try? container.decode(Bool.self, forKey: .firstShown)) ?? false
        secondShown = (try? container.decode(Bool.self, forKey: .secondShown)) ?? false
        sent = Stamps.decode(container, forKey: .sent)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(date, forKey: .date)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(Stamps.milliseconds(sent), forKey: .sent)
        try container.encode(firstShown, forKey: .firstShown)
        try container.encode(secondShown, forKey: .secondShown)
    }
}

package enum Reminder: String, Sendable, Equatable {
    case first, second, late
}

package enum DailyAction: Sendable, Equatable {
    case none
    // Make a draft, then tell the user.
    case run(Reminder)
    // The first reminder is already shown: tell the user again, with no new run.
    case notifySecond
}

package enum DailySchedule {
    // The second reminder comes this long before the deadline.
    package static let secondLead = Duration.seconds(600)
    private static var secondLeadMinutes: Int { Int(secondLead.components.seconds) / 60 }
    private static let lookBackDays = 7

    // What to do now. Marks of an earlier day count as fresh marks. Nothing happens before the
    // draft time; the first reminder comes from the draft time; the second comes 10 minutes before
    // the deadline; after the deadline a late start runs one time. The first and the second never
    // come together.
    package static func action(
        now: Date, _ settings: DailySettings, _ marks: DayMarks, calendar: Calendar
    ) -> DailyAction {
        let marks = today(marks, now: now, calendar: calendar)
        guard isActive(now, settings, marks, calendar: calendar) else { return .none }
        let time = minutes(now, calendar: calendar)
        let deadline = settings.deadline.minutes
        if time < settings.draftTime.minutes { return .none }
        if time < deadline - secondLeadMinutes {
            return marks.firstShown ? .none : .run(.first)
        }
        if time < deadline {
            switch (marks.firstShown, marks.secondShown) {
            case (false, false): return .run(.second)
            case (true, false): return .notifySecond
            default: return .none
            }
        }
        return marks.firstShown || marks.secondShown ? .none : .run(.late)
    }

    // The next moment that action can give another answer: the next draft time, second reminder
    // time, deadline or midnight on the wall clock. A time that the day does not have (a spring
    // change) gives the first time after the gap, so there is always a date.
    package static func nextWake(
        after now: Date, _ settings: DailySettings, _ marks: DayMarks, calendar: Calendar
    ) -> Date? {
        let times = [
            settings.draftTime,
            ClockTime(minutes: max(0, settings.deadline.minutes - secondLeadMinutes)),
            settings.deadline,
            ClockTime(hour: 0, minute: 0),
        ]
        return times.compactMap { time in
            calendar.nextDate(
                after: now,
                matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                matchingPolicy: .nextTime)
        }.min()
    }

    // True while the button of the side bar shows its marker: a due day with an area on, the
    // draft time is past, and not each area is sent or skipped. The marker stays until midnight.
    package static func showsMarker(
        now: Date, _ settings: DailySettings, _ marks: DayMarks, calendar: Calendar
    ) -> Bool {
        let marks = today(marks, now: now, calendar: calendar)
        return isActive(now, settings, marks, calendar: calendar)
            && minutes(now, calendar: calendar) >= settings.draftTime.minutes
    }

    // The start of the period for a draft: the last send, or else the start of the last due day
    // before today (looking back 7 days), or else one day ago.
    package static func since(
        now: Date, days: Set<Int>, lastSent: Date?, calendar: Calendar
    ) -> Date {
        if let lastSent { return lastSent }
        for back in 1...lookBackDays {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            if days.contains(dayNumber(day, calendar: calendar)) {
                return calendar.startOfDay(for: day)
            }
        }
        return calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86400)
    }

    // 0 is Sunday and 6 is Saturday.
    package static func dayNumber(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.weekday, from: date) - 1
    }

    private static func minutes(_ now: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private static func today(_ marks: DayMarks, now: Date, calendar: Calendar) -> DayMarks {
        let date = DayMarks.dateText(now, calendar: calendar)
        return marks.date == date ? marks : .fresh(date)
    }

    // A due day, an area that is on, and work left.
    private static func isActive(
        _ now: Date, _ settings: DailySettings, _ marks: DayMarks, calendar: Calendar
    ) -> Bool {
        settings.days.contains(dayNumber(now, calendar: calendar))
            && settings.areas.contains(where: \.on) && !marks.allDone(settings.areas)
    }
}
