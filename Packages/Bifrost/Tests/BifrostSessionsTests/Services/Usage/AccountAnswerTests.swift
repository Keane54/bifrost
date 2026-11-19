// The parse of the answer of the usage endpoint (docs/behaviour/usage.md, "The account values").
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

private let fetchedAt = utcMs(2026, 11, 7, 2, 0)
// The reset times in the form of the endpoint: six digits of fraction and an offset.
private let fiveHourReset = "2026-11-07T05:00:00.469616+00:00"
private let sevenDayReset = "2026-11-10T00:00:00+00:00"
private let fiveHourWindow = RateWindow(usedPercent: 37, resetsAt: utcMs(2026, 11, 7, 5, 0, 0, 470))
private let sevenDayWindow = RateWindow(usedPercent: 12.5, resetsAt: utcMs(2026, 11, 10))

private func data(_ json: JSONValue) throws -> Data { try JSONEncoder().encode(json) }

private func parse(_ json: JSONValue) throws -> AccountUsage? {
    AccountAnswer.parse(try data(json), fetchedAt: fetchedAt)
}

private func window(_ percent: JSONValue, _ resetsAt: JSONValue) -> JSONValue {
    ["utilization": percent, "resets_at": resetsAt]
}

private let fiveHour = window(37.0, .string(fiveHourReset))
private let sevenDay = window(12.5, .string(sevenDayReset))

@Suite("account answer")
struct AccountAnswerTests {
    @Test func theLimitIsOneMillionBytes() {
        #expect(AccountAnswer.maxBytes == 1_000_000)
    }

    @Test func anAnswerWithBothWindowsGivesTheValues() throws {
        let answer: JSONValue = [
            "five_hour": fiveHour, "seven_day": sevenDay,
            "seven_day_opus": window(3, "2026-11-10T00:00:00+00:00"),
            "extra_usage": ["is_enabled": true, "monthly_limit": 5000, "used_credits": 0],
        ]
        #expect(
            try parse(answer)
                == AccountUsage(
                    fetchedAt: fetchedAt,
                    limits: RateLimits(fiveHour: fiveHourWindow, sevenDay: sevenDayWindow),
                    extraUsage: true))
    }

    @Test func oneGoodWindowIsEnough() throws {
        #expect(try parse(["five_hour": fiveHour])?.limits == RateLimits(fiveHour: fiveHourWindow))
        #expect(
            try parse(["five_hour": .null, "seven_day": sevenDay])?.limits
                == RateLimits(sevenDay: sevenDayWindow))
    }

    @Test func aPercentAbove100Becomes100() throws {
        let answer: JSONValue = ["five_hour": window(130, .string(fiveHourReset))]
        #expect(try parse(answer)?.limits.fiveHour?.usedPercent == 100)
        #expect(try parse(["five_hour": window(0, .string(fiveHourReset))]) != nil)
    }

    @Test(arguments: [
        // The percent must be a number of 0 or more.
        window(-1, .string(fiveHourReset)), window("37", .string(fiveHourReset)),
        window(.null, .string(fiveHourReset)), window(true, .string(fiveHourReset)),
        ["resets_at": .string(fiveHourReset)],
        // The reset time must be an ISO 8601 text.
        window(37, .null), window(37, 1_794_027_600_000), window(37, "soon"),
        window(37, "2026-11-07"), ["utilization": 37],
        // A window must be an object.
        .null, 37, [37, .string(fiveHourReset)], "five hours",
    ] as [JSONValue])
    func aBadWindowGivesNoWindow(bad: JSONValue) throws {
        let answer: JSONValue = ["five_hour": bad, "seven_day": sevenDay]
        #expect(try parse(answer)?.limits == RateLimits(sevenDay: sevenDayWindow))
    }

    @Test func theWeeklyAllEntryOfTheLimitsIsTheSevenDayWindowWhenThatIsMissing() throws {
        let limits: JSONValue = [
            "not an entry",
            ["kind": "five_hour", "percent": 50, "resets_at": .string(sevenDayReset)],
            ["kind": "weekly_all", "percent": "55", "resets_at": .string(sevenDayReset)],
            ["kind": "weekly_all", "percent": 55, "resets_at": .string(sevenDayReset)],
            ["kind": "weekly_all", "percent": 66, "resets_at": .string(sevenDayReset)],
        ]
        let expected = RateWindow(usedPercent: 55, resetsAt: utcMs(2026, 11, 10))
        #expect(try parse(["limits": limits])?.limits == RateLimits(sevenDay: expected))
        #expect(
            try parse(["seven_day": .null, "limits": limits])?.limits
                == RateLimits(sevenDay: expected))
        // A bad seven-day object also falls back to the limits.
        #expect(
            try parse(["seven_day": window(-5, .string(sevenDayReset)), "limits": limits])?.limits
                == RateLimits(sevenDay: expected))
        // The entry uses the field percent, not utilization.
        let other: JSONValue = [
            ["kind": "weekly_all", "utilization": 55, "resets_at": .string(sevenDayReset)]
        ]
        #expect(try parse(["limits": other]) == nil)
        #expect(try parse(["limits": ["kind": "weekly_all"]]) == nil)
    }

    @Test func aGoodSevenDayObjectWinsOverTheLimits() throws {
        let limits: JSONValue = [
            ["kind": "weekly_all", "percent": 66, "resets_at": .string(sevenDayReset)]
        ]
        #expect(
            try parse(["seven_day": sevenDay, "limits": limits])?.limits
                == RateLimits(sevenDay: sevenDayWindow))
    }

    @Test(arguments: [
        [:], ["five_hour": .null, "seven_day": .null], ["other": fiveHour], ["limits": []],
        [fiveHour], "text", .null, 5,
    ] as [JSONValue])
    func anAnswerWithNoGoodWindowGivesNoData(answer: JSONValue) throws {
        #expect(try parse(answer) == nil)
    }

    @Test func theExtraUsageFlagComesOnlyFromABoolean() throws {
        func flag(_ extra: JSONValue?) throws -> Bool?? {
            var answer: [String: JSONValue] = ["five_hour": fiveHour]
            answer["extra_usage"] = extra
            return try parse(.object(answer)).map(\.extraUsage)
        }
        #expect(try flag(["is_enabled": false]) == .some(false))
        #expect(try flag(["is_enabled": true]) == .some(true))
        #expect(try flag(nil) == .some(nil))
        #expect(try flag(["is_enabled": "true"]) == .some(nil))
        #expect(try flag(["is_enabled": 1]) == .some(nil))
        #expect(try flag(["is_enabled": .null]) == .some(nil))
        #expect(try flag(true) == .some(nil))
        #expect(try flag([true]) == .some(nil))
    }

    @Test func aBodyOverOneMillionBytesIsABadAnswer() throws {
        let json = try data(["five_hour": fiveHour])
        let spaces = AccountAnswer.maxBytes - json.count
        let full = json + Data(repeating: UInt8(ascii: " "), count: spaces)
        #expect(full.count == 1_000_000)
        #expect(AccountAnswer.parse(full, fetchedAt: fetchedAt) != nil)
        #expect(AccountAnswer.parse(full + Data(" ".utf8), fetchedAt: fetchedAt) == nil)
    }

    @Test(arguments: [
        "", " ", "{", "not json", "{\"five_hour\":{\"utilization\":1e400}}",
    ])
    func aBodyThatIsNotJSONIsABadAnswer(text: String) {
        #expect(AccountAnswer.parse(Data(text.utf8), fetchedAt: fetchedAt) == nil)
        #expect(AccountAnswer.parse(Data([0xFF, 0xFE]), fetchedAt: fetchedAt) == nil)
    }

    @Test func theTimeOfTheAnswerIsTheTimeOfTheFetch() throws {
        let body = try data(["five_hour": fiveHour])
        #expect(AccountAnswer.parse(body, fetchedAt: 42)?.fetchedAt == 42)
    }
}
