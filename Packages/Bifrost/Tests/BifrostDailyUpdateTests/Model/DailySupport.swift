import BifrostFoundation
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The shared values of the Daily update tests. Each test pins its Calendar and its time zone.

func calendar(_ zone: String = "Europe/London") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

// A moment on the wall clock of the calendar.
func moment(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in calendar: Calendar
) -> Date {
    let parts = DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
    return calendar.date(from: parts) ?? .distantPast
}

// 2026-11-18 is a Wednesday. The default days are Monday to Friday, the draft time is 09:30 and
// the deadline is 10:00.
func wednesday(_ hour: Int, _ minute: Int, in calendar: Calendar = calendar()) -> Date {
    moment(2026, 11, 18, hour, minute, in: calendar)
}

let areaOne = WorkArea(id: "area-1", name: "Alpha")

func settings(areas: [WorkArea] = [areaOne]) -> DailySettings {
    var settings = DailySettings.defaults
    settings.areas = areas
    return settings
}

func fixtureData(_ name: String) throws -> Data {
    let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: folder.appending(path: name))
}

func fixtureJSON(_ name: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: fixtureData(name))
}
