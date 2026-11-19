import BifrostFoundation
import BifrostLayout
import BifrostTestSupport
import BifrostWindows
import Foundation
import Testing

// The window state file: the decode of window-state.json and its encode, the place of a
// restored window, and the flip between AppKit and the file. The tests of the store are in
// WindowStateStoreTests.swift. The labels of bounds are in the order
// height, width, x, y.

private func bounds(height: Double, width: Double, x: Double, y: Double) -> WindowBounds {
    WindowBounds(x: x, y: y, width: width, height: height)
}

private func boundsJSON(_ x: JSONValue, _ y: JSONValue, _ width: JSONValue, _ height: JSONValue)
    -> JSONValue
{
    ["height": height, "width": width, "x": x, "y": y]
}

// The state of a file with this JSON value, as the store reads it.
private func state(_ value: JSONValue) -> WindowState { loaded(value, else: WindowState()) }

private let screen = bounds(height: 1000, width: 1600, x: 0, y: 0)
private let fallback = RestoredPlace.centred(width: 1440, height: 900)

@Suite("the window state file")
struct WindowStateTests {
    @Test(
        "a value that is not an object gives the default state",
        arguments: [JSONValue.null, [], "x", 7, true])
    func notObject(value: JSONValue) {
        #expect(state(value) == WindowState(mode: .window, bounds: nil))
    }

    @Test(
        "one of the three modes stays and another value gives window",
        arguments: [
            (JSONValue.string("window"), DisplayMode.window), ("borderless", .borderless),
            ("fullscreen", .fullscreen), ("Window", .window), ("", .window), ("maximised", .window),
            (7, .window), (.null, .window), (.bool(true), .window),
            (.array(["fullscreen"]), .window),
        ])
    func mode(value: JSONValue, expected: DisplayMode) {
        #expect(state(["mode": value]).mode == expected)
    }

    @Test(
        "bounds need numbers, a width of 400 or more and a height of 300 or more",
        arguments: [
            (JSONValue.int(400), JSONValue.int(300), true), (.int(399), .int(300), false),
            (.int(400), .int(299), false), (.double(399.5), .int(300), false),
            (.double(400.5), .double(300.25), true), (.int(0), .int(0), false),
            (.int(-400), .int(300), false), (.int(1440), .int(900), true),
            (.string("400"), .int(300), false), (.null, .int(300), false),
            (.int(400), .bool(true), false),
        ])
    func boundsLimits(width: JSONValue, height: JSONValue, kept: Bool) {
        let decoded = state(["bounds": boundsJSON(10, 20, width, height)])
        #expect((decoded.bounds != nil) == kept)
    }

    @Test(
        "a position may be negative or have parts of a point",
        arguments: [(-200.0, -30.0), (-240.5, 25.0), (0.0, 0.0), (1600.0, -1055.0)])
    func position(x: Double, y: Double) {
        let decoded = state(["bounds": boundsJSON(.number(x), .number(y), 800, 600)])
        #expect(decoded.bounds == bounds(height: 600, width: 800, x: x, y: y))
    }

    @Test(
        "bounds with a bad position or a missing value are nil",
        arguments: [
            boundsJSON("1", 20, 800, 600), boundsJSON(10, .null, 800, 600),
            ["x": 1, "y": 2, "width": 800], "x", 7, .null, [10, 20, 800, 600],
        ])
    func badBounds(value: JSONValue) {
        #expect(state(["bounds": value, "mode": "borderless"]) == WindowState(mode: .borderless))
    }

    @Test("a bad mode keeps good bounds")
    func badModeKeepsBounds() {
        let decoded = state(["bounds": boundsJSON(-20, 10, 400, 300), "mode": "x"])
        let kept = bounds(height: 300, width: 400, x: -20, y: 10)
        #expect(decoded == WindowState(mode: .window, bounds: kept))
    }

    @Test("a file with no bounds has no bounds")
    func noBounds() {
        #expect(state(["mode": "fullscreen"]) == WindowState(mode: .fullscreen, bounds: nil))
    }

    // The state keeps each key that is not mode or bounds, and the encode writes it again.
    @Test func theStateKeepsTheUnknownKeys() throws {
        let decoded = state(["mode": "fullscreen", "display": ["id": 2], "zoom": 1.5])
        #expect(decoded.unknown.values == ["display": ["id": 2], "zoom": 1.5])
        let data = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(WindowState.self, from: data) == decoded)
    }

    @Test("the encode gives the mode, and the bounds or null")
    func encode() throws {
        #expect(try encoded(WindowState()) == ["bounds": .null, "mode": "window"])
        let place = bounds(height: 900, width: 1440, x: -240.5, y: 25)
        let saved = WindowState(mode: .fullscreen, bounds: place)
        #expect(
            try encoded(saved) == [
                "bounds": boundsJSON(-240.5, 25, 1440, 900), "mode": "fullscreen",
            ])
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(WindowState.self, from: data) == saved)
    }

    @Test("bounds with the top edge area on a screen stay")
    func keepsBounds() {
        let saved = bounds(height: 700, width: 900, x: 100, y: 80)
        #expect(WindowPlacement.restore(saved, workAreas: [screen]) == .at(saved))
        // Only a 100 x 40 part of the top edge area must be on the screen.
        let mostlyOff = bounds(height: 700, width: 900, x: 1500, y: 960)
        #expect(WindowPlacement.restore(mostlyOff, workAreas: [screen]) == .at(mostlyOff))
        // The window can be on a second screen.
        let second = bounds(height: 1000, width: 1600, x: 1600, y: 0)
        let onSecond = bounds(height: 700, width: 900, x: 1700, y: 50)
        #expect(WindowPlacement.restore(onSecond, workAreas: [screen, second]) == .at(onSecond))
    }

    @Test("bounds off all screens give only the fallback size")
    func fallbackSize() {
        #expect(WindowPlacement.restore(nil, workAreas: [screen]) == fallback)
        let off = bounds(height: 700, width: 900, x: 3000, y: 80)
        #expect(WindowPlacement.restore(off, workAreas: [screen]) == fallback)
        // The top edge area is above the screen.
        let above = bounds(height: 700, width: 900, x: 100, y: -700)
        #expect(WindowPlacement.restore(above, workAreas: [screen]) == fallback)
        // Only 50 pixels of the width is on the screen.
        let narrow = bounds(height: 700, width: 900, x: 1550, y: 80)
        #expect(WindowPlacement.restore(narrow, workAreas: [screen]) == fallback)
        #expect(WindowPlacement.restore(off, workAreas: []) == fallback)
    }

    // The file keeps the screen coordinates of the Electron app: the origin is the
    // top-left corner of the primary screen, and y goes down. AppKit puts the origin at the
    // bottom-left corner of the primary screen, and y goes up. Here the primary screen is 1440 by
    // 900 points with a menu bar of 25, and a second screen of 1920 by 1080 is above it.
    @Test func theBoundsFlipBetweenAppKitAndTheFile() {
        let height = 900.0
        // The visible frames of the two screens, as AppKit gives them.
        let primary = WindowBounds(x: 0, y: 0, width: 1440, height: 875)
        let upper = WindowBounds(x: -240, y: 900, width: 1920, height: 1055)
        let areas = [primary, upper].map {
            WindowPlacement.fileBounds(appKit: $0, primaryScreenHeight: height)
        }
        // The work areas that Electron gives for the same screens.
        #expect(
            areas == [
                WindowBounds(x: 0, y: 25, width: 1440, height: 875),
                WindowBounds(x: -240, y: -1055, width: 1920, height: 1055),
            ])
        // A window on the upper screen. Its top edge is 55 points below the top of the visible
        // area.
        let window = WindowBounds(x: 100, y: 1200, width: 1000, height: 700)
        let saved = WindowPlacement.fileBounds(appKit: window, primaryScreenHeight: height)
        #expect(saved == WindowBounds(x: 100, y: -1000, width: 1000, height: 700))
        #expect(WindowPlacement.restore(saved, workAreas: areas) == .at(saved))
        #expect(WindowPlacement.appKitFrame(saved, primaryScreenHeight: height) == window)
        // A window on the primary screen, saved by the Electron app.
        let electron = WindowBounds(x: 200, y: 100, width: 800, height: 600)
        #expect(WindowPlacement.restore(electron, workAreas: areas) == .at(electron))
        #expect(
            WindowPlacement.appKitFrame(electron, primaryScreenHeight: height)
                == WindowBounds(x: 200, y: 200, width: 800, height: 600))
    }

    // A window-state.json from a screen set-up with a display that is not there
    // now. The window opens in the centre at the default size, so it is on a screen.
    @Test func aWindowOnAMissingScreenOpensCentred() {
        let primary = WindowBounds(x: 0, y: 25, width: 1440, height: 875)
        // The window was on a screen at the right, and on a screen above the primary screen.
        let right = WindowBounds(x: 1600, y: 100, width: 1200, height: 800)
        let above = WindowBounds(x: 100, y: -1000, width: 1000, height: 700)
        let centred = RestoredPlace.centred(
            width: WindowPlacement.defaultWidth, height: WindowPlacement.defaultHeight)
        #expect(centred == .centred(width: 1440, height: 900))
        #expect(WindowPlacement.restore(right, workAreas: [primary]) == centred)
        #expect(WindowPlacement.restore(above, workAreas: [primary]) == centred)
        // With the screen above connected again, the window opens at its place.
        let upper = WindowBounds(x: -240, y: -1055, width: 1920, height: 1055)
        #expect(WindowPlacement.restore(above, workAreas: [primary, upper]) == .at(above))
    }
}
