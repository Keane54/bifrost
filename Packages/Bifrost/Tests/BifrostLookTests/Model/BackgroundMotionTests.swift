import BifrostLook
import Testing

// The state of the motion of the background (docs/behaviour/look.md). The rule is
// BackgroundMotion.phase. The value BackgroundMotion keeps the
// inputs of the rule for the shell: the setting, the window, reduced motion, and if the fields
// moved before in this run.

private func phase(active: Bool, animated: Bool, ran: Bool, reduced: Bool)
    -> BackgroundMotion.Phase
{
    BackgroundMotion.phase(setting: animated, ran: ran, active: active, reduced: reduced)
}

@Suite("the state of the motion")
struct BackgroundMotionTests {
    @Test
    func movesWithSettingAndActiveWindow() {
        #expect(phase(active: true, animated: true, ran: true, reduced: false) == .moving)
        #expect(phase(active: true, animated: true, ran: false, reduced: false) == .moving)
        var motion = BackgroundMotion(setting: true, reduceMotion: false)
        #expect(!motion.moving)
        motion.setWindowActive(true)
        #expect(motion.moving)
        #expect(motion.phase == .moving)
    }

    // No motion while the window does not have the focus or is hidden. The fields stay where
    // they are and continue from there.
    @Test
    func pausesWhileInactive() {
        #expect(phase(active: false, animated: true, ran: true, reduced: false) == .paused)
        #expect(phase(active: false, animated: true, ran: false, reduced: false) == .paused)
        var motion = BackgroundMotion(setting: true, reduceMotion: false)
        motion.setWindowActive(true)
        motion.setWindowActive(false)
        #expect(motion.phase == .paused)
        #expect(!motion.moving)
    }

    @Test
    func pausesWhenTheSettingGoesOff() {
        #expect(phase(active: true, animated: false, ran: true, reduced: false) == .paused)
        #expect(phase(active: false, animated: false, ran: true, reduced: false) == .paused)
        var motion = BackgroundMotion(setting: true, reduceMotion: false)
        motion.setWindowActive(true)
        motion.setSetting(false)
        #expect(motion.phase == .paused)
        motion.setWindowActive(false)
        #expect(motion.phase == .paused)
    }

    @Test
    func stillWhenOffFromTheStart() {
        #expect(phase(active: true, animated: false, ran: false, reduced: false) == .still)
        #expect(phase(active: false, animated: false, ran: false, reduced: false) == .still)
        var motion = BackgroundMotion(setting: false, reduceMotion: false)
        motion.setWindowActive(true)
        #expect(motion.phase == .still)
        // A setting that goes on later moves the fields. Off again, they pause in place.
        motion.setSetting(true)
        #expect(motion.phase == .moving)
        motion.setSetting(false)
        #expect(motion.phase == .paused)
    }

    // With reduced motion, the layers stay at their still position in each state.
    @Test
    func stillWithReducedMotion() {
        for active in [true, false] {
            for animated in [true, false] {
                for ran in [true, false] {
                    #expect(
                        phase(active: active, animated: animated, ran: ran, reduced: true)
                            == .still)
                }
            }
        }
        var motion = BackgroundMotion(setting: true, reduceMotion: true)
        motion.setWindowActive(true)
        #expect(motion.phase == .still)
        motion.setReduceMotion(false)
        #expect(motion.phase == .moving)
        motion.setReduceMotion(true)
        #expect(motion.phase == .still)
    }

    @Test("the window is active only with focus and a visible page")
    func windowActive() {
        #expect(BackgroundMotion.windowActive(focused: true, visible: true))
        #expect(!BackgroundMotion.windowActive(focused: false, visible: true))
        #expect(!BackgroundMotion.windowActive(focused: true, visible: false))
        #expect(!BackgroundMotion.windowActive(focused: false, visible: false))
    }
}
