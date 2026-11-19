import Foundation

// A wall time in milliseconds since 1970, from a date and a time in UTC. It is the form of the
// session rows and of RateWindow.resetsAt. The month is 1 to 12.
package func utcMs(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
    _ millisecond: Int = 0
) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts = DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    guard let date = calendar.date(from: parts) else { preconditionFailure("not a date: \(parts)") }
    return Int(date.timeIntervalSince1970) * 1000 + millisecond
}
