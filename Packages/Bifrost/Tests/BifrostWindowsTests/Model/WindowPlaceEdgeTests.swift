import Testing

@testable import BifrostWindows

// The edge cases of the place of a saved window (window-state.json).
@Suite("the place of a saved window")
struct SavedWindowPlaceEdgeTests {
    private let screen = WindowBounds(x: 0, y: 0, width: 1440, height: 900)

    @Test(
        "a saved window stays when 100 by 40 points of its top edge are on a screen",
        arguments: [
            // (x, y, width, expected to stay)
            (0.0, 0.0, 800.0, true), (1340.0, 0.0, 800.0, true), (1341.0, 0.0, 800.0, false),
            (-700.0, 0.0, 800.0, true), (-701.0, 0.0, 800.0, false), (100.0, 860.0, 800.0, true),
            (100.0, 861.0, 800.0, false), (100.0, -1.0, 800.0, false), (100.0, 0.0, 99.0, false),
            (1440.0, 100.0, 800.0, false), (100.0, 5000.0, 800.0, false),
        ])
    func visible(x: Double, y: Double, width: Double, stays: Bool) {
        let saved = WindowBounds(x: x, y: y, width: width, height: 600)
        let place = WindowPlacement.restore(saved, workAreas: [screen])
        #expect((place == .at(saved)) == stays)
        if !stays { #expect(place == .centred(width: 1440, height: 900)) }
    }

    @Test("no saved bounds or no screen opens the window in the centre")
    func noBounds() {
        #expect(
            WindowPlacement.restore(nil, workAreas: [screen]) == .centred(width: 1440, height: 900))
        let saved = WindowBounds(x: 0, y: 0, width: 800, height: 600)
        #expect(WindowPlacement.restore(saved, workAreas: []) == .centred(width: 1440, height: 900))
    }

    @Test("a saved window on a second screen stays while that screen is there")
    func secondScreen() {
        let second = WindowBounds(x: 1440, y: 0, width: 1920, height: 1080)
        let saved = WindowBounds(x: 1600, y: 100, width: 800, height: 600)
        #expect(WindowPlacement.restore(saved, workAreas: [screen, second]) == .at(saved))
        #expect(
            WindowPlacement.restore(saved, workAreas: [screen])
                == .centred(width: 1440, height: 900))
    }
}
