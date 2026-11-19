import BifrostSessions
import BifrostTestSupport
import Testing

// The choice of the usage values (the section "Where the usage values come from" of
// docs/behaviour/usage.md).

private let now = utcMs(2026, 11, 10, 12, 0)
private let minute = 60_000

private let snapshot = UsageSnapshot(
    sessionId: "abcdef12-0000", name: "bifrost-test-a", updatedAt: now - 2 * minute,
    limits: RateLimits(fiveHour: RateWindow(usedPercent: 40, resetsAt: now + 60 * minute)))

private func account(age: Int) -> AccountUsage {
    AccountUsage(
        fetchedAt: now - age,
        limits: RateLimits(
            sevenDay: RateWindow(usedPercent: 91, resetsAt: now + 3 * 24 * 60 * minute)))
}

@Suite("usage source")
struct UsageSourceTests {
    @Test func theLimitsAre70And90PercentAnd15Minutes() {
        #expect(UsageSource.raisedAbovePercent == 70)
        #expect(UsageSource.highPercent == 90)
        #expect(UsageSource.accountMaxAge == .seconds(15 * 60))
    }

    @Test func theAccountValuesWinWhileTheyAre15MinutesOldOrLess() {
        let fresh = account(age: 15 * minute)
        #expect(UsageSource.pick(snapshot, now: now, fresh) == .account(fresh))
        #expect(UsageSource.pick(snapshot, now: now, fresh)?.limits == fresh.limits)
        // The account values win also when they lack a window that the session values have.
        #expect(UsageSource.pick(snapshot, now: now, account(age: 0))?.limits.fiveHour == nil)
    }

    @Test func accountValuesFromAfterNowWin() {
        let ahead = account(age: -5 * minute)
        #expect(UsageSource.pick(snapshot, now: now, ahead) == .account(ahead))
    }

    @Test func olderAccountValuesFallBackToTheSessionValues() {
        let source = UsageSource.pick(snapshot, now: now, account(age: 15 * minute + 1))
        #expect(source == .session(snapshot))
        #expect(source?.limits == snapshot.limits)
        #expect(UsageSource.pick(snapshot, now: now, nil) == .session(snapshot))
    }

    @Test func noValuesGiveNoSource() {
        #expect(UsageSource.pick(nil, now: now, nil) == nil)
        #expect(UsageSource.pick(nil, now: now, account(age: 16 * minute)) == nil)
    }

    // The age of the account values never overflows: values from the far past are old.
    @Test func accountValuesFromTheFarPastAreOld() {
        let ancient = AccountUsage(fetchedAt: Int.min, limits: RateLimits())
        #expect(UsageSource.pick(snapshot, now: Int.max, ancient) == .session(snapshot))
        let future = AccountUsage(fetchedAt: Int.max, limits: RateLimits())
        #expect(UsageSource.pick(snapshot, now: Int.min, future) == .account(future))
    }

    @Test func theExtraUsageFlagIsUnknownUntilTheAnswerGivesIt() {
        let usage = AccountUsage(fetchedAt: now, limits: RateLimits())
        #expect(usage.extraUsage == nil)
        let on = AccountUsage(fetchedAt: now, limits: RateLimits(), extraUsage: true)
        #expect(on.extraUsage == true)
    }
}
