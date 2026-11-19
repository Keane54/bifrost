// How far a usage limit is used. The bar of a limit takes its colour from the level, for the
// 5-hour bar and the 7-day bar alike (docs/behaviour/usage.md, "The Usage HUD").
package enum UsageLevel: String, Sendable, Equatable, CaseIterable {
    // Up to UsageSource.raisedAbovePercent.
    case normal
    // Above UsageSource.raisedAbovePercent, and below UsageSource.highPercent.
    case raised
    // From UsageSource.highPercent.
    case high

    // The level of a rounded percent. nil (no value is known) is normal.
    package init(percent: Int?) {
        guard let percent else {
            self = .normal
            return
        }
        if percent >= UsageSource.highPercent {
            self = .high
        } else if percent > UsageSource.raisedAbovePercent {
            self = .raised
        } else {
            self = .normal
        }
    }
}
