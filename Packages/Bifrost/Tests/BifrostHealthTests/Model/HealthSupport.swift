import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostHealth

// The sample answers of the status pages (Fixtures).
func fixture(_ name: String) throws -> Data {
    let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: folder.appending(path: name))
}

// A wall time in UTC.
func wall(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
) -> Date {
    Date(timeIntervalSince1970: Double(utcMs(year, month, day, hour, minute)) / 1000)
}
