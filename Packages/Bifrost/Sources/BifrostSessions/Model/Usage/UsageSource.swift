// The usage values of the Anthropic account: the answer of the usage endpoint. fetchedAt is the
// wall time of the answer in milliseconds since 1970. extraUsage is true when extra usage (the
// spend above the plan) is on, and nil when the answer gives no flag.
package struct AccountUsage: Sendable, Equatable {
    package var fetchedAt: Int
    package var limits: RateLimits
    package var extraUsage: Bool?

    package init(fetchedAt: Int, limits: RateLimits, extraUsage: Bool? = nil) {
        self.fetchedAt = fetchedAt
        self.limits = limits
        self.extraUsage = extraUsage
    }
}

// The source of the usage values (docs/behaviour/usage.md, "Where the usage values come from").
// The Usage HUD and the usage notification both use pick, so they cannot disagree.
package enum UsageSource: Sendable, Equatable {
    case account(AccountUsage)
    case session(UsageSnapshot)

    // From this percent, a limit is high. The HUD and the usage notification compare the rounded
    // percent with it. The HUD bar then uses the high colour (red), and Bifrost shows the usage
    // notification.
    package static let highPercent = 90

    // Above this percent, and below highPercent, a limit is raised. The HUD bar then uses the
    // raised colour (amber). There is no notification for this level.
    package static let raisedAbovePercent = 70

    // Account values older than this fall back to the session values.
    package static let accountMaxAge = Duration.seconds(900)

    // The account values when they are 15 minutes old or less, also when they are from after
    // now. Else the newest session values from the usage lines. nil when neither is available.
    // The age is a Duration, so a time far from now does not overflow.
    package static func pick(_ snapshot: UsageSnapshot?, now: Int, _ account: AccountUsage?)
        -> UsageSource?
    {
        if let account, .milliseconds(now) - .milliseconds(account.fetchedAt) <= accountMaxAge {
            return .account(account)
        }
        return snapshot.map { .session($0) }
    }

    // The windows of the source.
    package var limits: RateLimits {
        switch self {
        case .account(let account): account.limits
        case .session(let snapshot): snapshot.limits
        }
    }
}
