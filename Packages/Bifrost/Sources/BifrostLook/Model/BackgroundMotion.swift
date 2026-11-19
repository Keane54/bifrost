// The state of the motion of the animated background (docs/behaviour/look.md, "The animated
// background"). The fields move only with the Animated background setting on, an active window and
// no reduced motion. An inactive window pauses them. A setting that goes off after the fields moved
// also pauses them, so they do not jump. A setting that is off from the start keeps them at the
// still position. With reduced motion, the fields stay at the still position in each case.
public struct BackgroundMotion: Sendable, Equatable {
    // moving: the fields drift. paused: the fields stop where they are, and continue from there.
    // still: the fields stay at their still position, the first step of each cycle.
    public enum Phase: Sendable, Equatable {
        case moving, paused, still
    }

    private var setting: Bool
    private var reduceMotion: Bool
    private var active = false
    // True when the setting was on in this run of the app.
    private var ran: Bool

    // The window is not active until the shell calls setWindowActive.
    public init(setting: Bool, reduceMotion: Bool) {
        self.setting = setting
        self.reduceMotion = reduceMotion
        ran = setting
    }

    public mutating func setWindowActive(_ active: Bool) { self.active = active }

    public mutating func setSetting(_ on: Bool) {
        setting = on
        if on { ran = true }
    }

    public mutating func setReduceMotion(_ on: Bool) { reduceMotion = on }

    public var phase: Phase {
        Self.phase(setting: setting, ran: ran, active: active, reduced: reduceMotion)
    }

    package var moving: Bool { phase == .moving }

    // The rule of the phase.
    package static func phase(setting: Bool, ran: Bool, active: Bool, reduced: Bool) -> Phase {
        if reduced { return .still }
        if setting { return active ? .moving : .paused }
        return ran ? .paused : .still
    }

    // True when the window has the focus and is visible. The window has the focus only while it
    // is the key window.
    public static func windowActive(focused: Bool, visible: Bool) -> Bool {
        focused && visible
    }
}
