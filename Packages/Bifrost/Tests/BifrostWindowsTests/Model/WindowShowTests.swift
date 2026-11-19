import BifrostLayout
import BifrostWindows
import Testing

// The rules of the show of the window: the Dock icon, the headless flag of a test home and the
// show after the start. The rule of each part is in WindowShow.

@Suite("showing the window")
struct WindowShowTests {
    // A normal start shows the window and makes the app active. The native app has no focus
    // flag: a reopen from the Dock makes the app active by itself.
    @Test("a normal start shows the window as before")
    func aNormalStart() {
        #expect(WindowShow.show(testHome: false, headless: false) == .normal)
    }

    @Test("a test home never focuses the window")
    func aTestHome() {
        #expect(WindowShow.show(testHome: true, headless: false) == .inactive)
    }

    @Test
    func aHeadlessTestHome() {
        #expect(WindowShow.show(testHome: true, headless: true) == .none)
    }

    @Test
    func aNormalStartIgnoresHeadless() {
        #expect(WindowShow.show(testHome: false, headless: true) == .normal)
    }

    @Test
    func aHeadlessTestHomeIsAnAccessory() {
        #expect(WindowShow.accessory(testHome: true, headless: true))
    }

    @Test
    func notHeadlessKeepsTheDockIcon() {
        #expect(!WindowShow.accessory(testHome: true, headless: false))
        #expect(!WindowShow.accessory(testHome: false, headless: false))
    }

    // The native app runs only on macOS. The nearest rule: the headless flag without a test home
    // keeps the Dock icon, because the headless flag counts only with a test home.
    @Test
    func theFlagNeedsATestHome() {
        #expect(!WindowShow.accessory(testHome: false, headless: true))
    }

    @Test
    func headlessCountsAsVisible() {
        #expect(WindowShow.seenVisible(false, headless: true))
        #expect(WindowShow.seenVisible(true, headless: true))
        // A window that is not headless keeps the visibility of the window.
        #expect(!WindowShow.seenVisible(false, headless: false))
        #expect(WindowShow.seenVisible(true, headless: false))
    }

    @Test
    func headlessCountsAsFocused() {
        #expect(WindowShow.seenFocused(false, headless: true))
        #expect(WindowShow.seenFocused(true, headless: true))
        #expect(!WindowShow.seenFocused(false, headless: false))
        #expect(WindowShow.seenFocused(true, headless: false))
    }

    // The start-error alert makes the app active first, so it shows in front.
    // With a test home it never takes the focus from the app of the user.
    @Test func theStartAlertActivatesOnlyWithoutATestHome() {
        #expect(WindowShow.alertActivates(testHome: false))
        #expect(!WindowShow.alertActivates(testHome: true))
    }

    // The headless flag: BIFROST_TEST_HEADLESS=1 with a test home. Another value or
    // no test home gives false.
    @Test func theHeadlessFlagNeedsATestHomeAndTheValue1() {
        let on = [WindowShow.headlessKey: "1"]
        #expect(WindowShow.headlessKey == "BIFROST_TEST_HEADLESS")
        #expect(WindowShow.headless(testHome: true, environment: on))
        #expect(!WindowShow.headless(testHome: false, environment: on))
        #expect(!WindowShow.headless(testHome: true, environment: [WindowShow.headlessKey: "true"]))
        #expect(!WindowShow.headless(testHome: true, environment: [:]))
    }

    // The window acts as the key window only with a test home in a Debug
    // build, so the test port can type into it while another app has the focus.
    @Test func onlyATestHomeInADebugBuildActsAsKey() {
        #expect(WindowShow.actsAsKey(testHome: true, debugBuild: true))
        #expect(!WindowShow.actsAsKey(testHome: true, debugBuild: false))
        #expect(!WindowShow.actsAsKey(testHome: false, debugBuild: true))
        #expect(!WindowShow.actsAsKey(testHome: false, debugBuild: false))
    }

    // A test home never applies a saved full screen. The other saved modes apply in each show.
    @Test func aTestHomeShowSkipsASavedFullScreen() {
        #expect(WindowShow.appliesSavedMode(.fullscreen, show: .normal))
        #expect(!WindowShow.appliesSavedMode(.fullscreen, show: .inactive))
        #expect(!WindowShow.appliesSavedMode(.fullscreen, show: .none))
        for show in [WindowShow.Show.normal, .inactive, .none] {
            #expect(WindowShow.appliesSavedMode(.window, show: show))
            #expect(WindowShow.appliesSavedMode(.borderless, show: show))
        }
    }
}
