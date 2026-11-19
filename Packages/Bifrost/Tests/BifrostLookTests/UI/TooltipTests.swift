import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostLook

// The look of the tooltip (docs/behaviour/look.md): the title colour, a border of 1 in the panel
// edge colour, the text colour, Geist Mono at 12 (text-xs), a padding of 8 by 4 inside the
// border, and a line break in the text starts a new line.
@MainActor
@Suite("tooltip", .timeLimit(.minutes(1)), .tags(.window))
struct TooltipTests {
    init() { UITestApp.prepare() }

    @Test func theTipHasTheFontThePaddingAndTheColoursOfTheTokens() throws {
        #expect(Fonts.register())
        let controller = TooltipController()
        let tip = controller.makeTip("Restore Settings\nCmd+1")
        let layer = try #require(tip.layer)
        #expect(layer.backgroundColor == ThemeTokens.title.cgColor)
        #expect(layer.borderColor == ThemeTokens.panelEdge.cgColor)
        #expect(layer.borderWidth == 1)
        #expect(layer.cornerRadius == 0)
        let label = try #require(tip.subviews.first as? NSTextField)
        #expect(label.stringValue == "Restore Settings\nCmd+1")
        #expect(label.textColor == ThemeTokens.text.nsColor)
        #expect(label.font?.fontName == "GeistMono-Regular")
        #expect(label.font?.pointSize == 12)
        #expect(label.frame.minX == 9)
        #expect(label.frame.minY == 5)
        #expect(tip.frame.width == label.frame.width + 18)
        #expect(tip.frame.height == label.frame.height + 10)
        // Two lines of 16.
        #expect(label.frame.height == 32)
    }

    @Test func theTipScalesWithTheInterfaceScale() throws {
        #expect(Fonts.register())
        let controller = TooltipController()
        controller.metrics = CanvasMetrics(interfaceScale: 150)
        let tip = controller.makeTip("Minimise")
        let label = try #require(tip.subviews.first as? NSTextField)
        #expect(label.font?.pointSize == 18)
        #expect(label.frame.minX == 13.5)
        #expect(label.frame.minY == 7.5)
        #expect(tip.layer?.borderWidth == 1.5)
    }

    // white-space: pre-line wraps a long line at the edge of the window.
    @Test func aLongLineWrapsAtTheWidthOfTheWindow() throws {
        #expect(Fonts.register())
        let controller = TooltipController()
        let text = "Restore the frame of the session list with the name of the project"
        let wide = controller.makeTip(text)
        let narrow = controller.makeTip(text, maxWidth: 200)
        let label = try #require(narrow.subviews.first as? NSTextField)
        #expect(wide.frame.width > 200)
        // One line of 16, the padding of 4 and the border of 1 at each side.
        #expect(wide.frame.height == 26)
        #expect(narrow.frame.width <= 200)
        #expect(label.frame.height >= 32)
        #expect(label.frame.height.truncatingRemainder(dividingBy: 16) == 0)
    }

    // The monitor of the presses and the Esc key stays while a tooltip waits or shows, also the
    // tooltip of a keyboard focus.
    @Test func thePressMonitorStaysWhileATooltipWaits() {
        let controller = TooltipController()
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        let second = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        controller.attach("Minimise", to: first, side: .top)
        controller.attach("Close", to: second, side: .top)
        controller.focused(first)
        #expect(controller.watchesPresses)
        // The pointer leaves another view: the tooltip of the focus still waits.
        controller.unfocused(second)
        #expect(controller.watchesPresses)
        controller.unfocused(first)
        #expect(!controller.watchesPresses)
    }

    // The delay of a tooltip waits on the clock of the owner. The pointer
    // comes to the view: one sleeper of the delay waits on the manual clock. The pointer leaves:
    // the timer stops.
    @Test func theDelayWaitsOnTheClockOfTheOwner() async throws {
        let clock = ManualClock()
        let controller = TooltipController(clock: clock)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        controller.attach("Close", to: view, side: .top)
        let owner = try #require(view.trackingAreas.first?.owner as? NSResponder)
        func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.enterExitEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                    userData: nil))
        }
        owner.mouseEntered(with: try crossing(.mouseEntered))
        await clock.waitForSleepers(exactly: 1)
        owner.mouseExited(with: try crossing(.mouseExited))
        await clock.waitUntilNoSleepers()
        controller.detach(from: view)
    }

    // Each move of the pointer before the tooltip shows starts the delay again. The moves keep
    // the one wait: no move stops the wait and starts a new one.
    @Test func movesOfThePointerKeepOneWait() async throws {
        let clock = ManualClock()
        let controller = TooltipController(clock: clock)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        controller.attach("Close", to: view, side: .top)
        let owner = try #require(view.trackingAreas.first?.owner as? NSResponder)
        let entered = try #require(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let moved = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        owner.mouseEntered(with: entered)
        await waitUntil { clock.sleeperCount == 1 }
        for _ in 0..<5 {
            owner.mouseMoved(with: moved)
            #expect(clock.sleeperCount == 1)
        }
        controller.detach(from: view)
        await waitUntil { clock.sleeperCount == 0 }
    }

    // A tooltip with the screen as its area: at the right of its view with room, flipped to the
    // left at the right edge of the screen, and moved up to stay inside its bottom edge.
    @Test func aTipInTheScreenAreaFlipsAtTheEdgeOfTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tip = CGSize(width: 200, height: 26)
        let anchor = CGRect(x: 300, y: 400, width: 144, height: 20)
        let right = TooltipController.screenFrame(
            tip: tip, anchor: anchor, side: .right, screen: screen, scale: 1)
        #expect(right.minX == anchor.maxX + 6)
        #expect(right.midY == anchor.midY)
        let edge = CGRect(x: 850, y: 400, width: 144, height: 20)
        let flipped = TooltipController.screenFrame(
            tip: tip, anchor: edge, side: .right, screen: screen, scale: 1)
        #expect(flipped.maxX == edge.minX - 6)
        let low = CGRect(x: 300, y: 0, width: 144, height: 10)
        let raised = TooltipController.screenFrame(
            tip: tip, anchor: low, side: .right, screen: screen, scale: 1)
        #expect(raised.minY == screen.minY + 5)
        // A view keeps its area until a new attach.
        let controller = TooltipController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        controller.attach("Later.", to: view, side: .right, area: .screen)
        #expect(controller.area(of: view) == .screen)
        controller.attach("Later.", to: view, side: .right)
        #expect(controller.area(of: view) == .window)
    }

    @Test func attachAddsOneTrackingAreaAndDetachRemovesIt() {
        let controller = TooltipController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        controller.attach("Close", to: view, side: .top)
        controller.attach("Close panel", to: view, side: .right)
        #expect(view.trackingAreas.count == 1)
        #expect(controller.text(of: view) == "Close panel")
        controller.detach(from: view)
        #expect(view.trackingAreas.isEmpty)
        #expect(controller.text(of: view) == nil)
    }
}
