// A seeded property test of the window layout (WindowLayout.apply). Each run starts from empty
// bounds and applies up to 30 random actions of every kind, with bad rects and bad bounds. After
// each step the test checks the rules of the layout. A failure prints the seed, the run and the
// action list so that the case can be replayed: run the same run number with the same seed.
import BifrostLayout
import Testing

// A small generator with a fixed algorithm, so a seed gives the same runs on every machine.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let seed: UInt64 = 0x00B1_F205_7000_0001
private let runCount = 500
private let maxActions = 30

private let panels: [PanelID] = [
    "settings", "watchlist", "event-log", "usage-hud", "overview:1", "overview:2",
    "overview-settings:1", "chat:123e4567-e89b-12d3-a456-426614174000",
    "chat:123e4567-e89b-12d3-a456-426614174001", "module:alpha-one:main",
].map {
    guard let id = PanelID($0) else { preconditionFailure("not a panel ID: \($0)") }
    return id
}

private struct Source {
    var rng: SplitMix64

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func chance(_ percent: Int) -> Bool { int(1...100) <= percent }
    mutating func panel() -> PanelID { panels[int(0...(panels.count - 1))] }

    mutating func number(small: Bool = false) -> Double {
        switch int(0...9) {
        case 0: return Double.nan
        case 1: return int(0...1) == 0 ? Double.infinity : -Double.infinity
        case 2: return Double(int(-500...0))
        case 3: return Double(int(1...5000))
        case 4: return 1e300
        default: return Double(int(small ? 0...300 : 0...1600)) + (chance(20) ? 0.5 : 0)
        }
    }

    mutating func rect() -> LayoutRect {
        LayoutRect(x: number(), y: number(), w: number(small: true), h: number(small: true))
    }

    // A frame ID that exists, or one that does not (0, a number above nextFrame).
    mutating func frame(_ layout: WindowLayout) -> FrameID {
        if !layout.frames.isEmpty && chance(85) {
            return layout.frames[int(0...(layout.frames.count - 1))].id
        }
        return FrameID(number: int(0...(layout.nextFrame + 3)))
    }

    mutating func bounds() -> LayoutSize {
        switch int(0...9) {
        case 0: LayoutSize(w: number(), h: number())
        case 1: LayoutSize(w: Double(int(1...199)), h: Double(int(1...119)))
        default: LayoutSize(w: Double(int(200...2400)), h: Double(int(120...1600)))
        }
    }

    mutating func snapshot(_ layout: WindowLayout) -> LayoutSnapshot {
        var frames: [SavedFrame] = []
        for _ in 0...int(0...4) {
            var list: [PanelID] = []
            for _ in 0...int(0...3) { list.append(panel()) }
            frames.append(
                SavedFrame(
                    panels: list, active: panel(), rect: rect(), minimised: chance(30),
                    locked: chance(30)))
        }
        var memory: [PanelID: LayoutRect] = [:]
        for _ in 0...int(0...3) { memory[panel()] = rect() }
        return LayoutSnapshot(frames: frames, memory: memory)
    }

    mutating func action(_ layout: WindowLayout) -> WindowAction {
        switch int(0...13) {
        case 0: .open(panel())
        case 1: .close(panel())
        case 2: .replace(panel(), with: panel())
        case 3: .closeActive
        case 4: .focus(frame(layout))
        case 5: .setRect(frame(layout), rect())
        case 6: .stack(frame(layout), onto: frame(layout))
        case 7: .unstack(panel(), rect())
        case 8: .activate(panel())
        case 9: .minimise(frame(layout))
        case 10: .restore(frame(layout))
        case 11: .lock(frame(layout), chance(50))
        case 12: .bounds(bounds())
        default: .load(snapshot(layout))
        }
    }
}

// The first broken rule after a step, or nil.
private func broken(
    _ before: WindowLayout, _ action: WindowAction, _ changed: Bool, _ after: WindowLayout
) -> String? {
    if let rule = shapeRule(after) { return rule }
    if !changed && after != before { return "an action that reports no change changed the layout" }
    if after.nextFrame < before.nextFrame { return "nextFrame went down" }
    if let rule = shownRule(after) { return rule }
    if let rule = actionRule(before, action, changed, after) { return rule }
    return roundTripRule(after)
}

private func shapeRule(_ layout: WindowLayout) -> String? {
    var ids = Set<Int>()
    var seen = Set<PanelID>()
    for frame in layout.frames {
        if !ids.insert(frame.id.number).inserted { return "frame ID \(frame.id.text) repeats" }
        if frame.id.number < 1 || frame.id.number >= layout.nextFrame {
            return "frame ID \(frame.id.text) is not below nextFrame \(layout.nextFrame)"
        }
        if frame.panels.isEmpty { return "frame \(frame.id.text) has no panel" }
        if !frame.panels.contains(frame.active) { return "active is not in panels" }
        for panel in frame.panels where !seen.insert(panel).inserted {
            return "panel \(panel) is in two places"
        }
        if !(frame.rect.x.isFinite && frame.rect.y.isFinite && frame.rect.w.isFinite
            && frame.rect.h.isFinite)
        {
            return "frame \(frame.id.text) has a rect that is not finite"
        }
    }
    let bounds = layout.bounds
    if !(bounds.w.isFinite && bounds.h.isFinite && bounds.w >= 1 && bounds.h >= 1) {
        return "bounds are bad"
    }
    return nil
}

// A shown rect is in the bounds, and at least the minimum size when the bounds allow it. This
// includes a saved rect with half units from a file, and bounds with a half unit.
private func shownRule(_ layout: WindowLayout) -> String? {
    let bounds = layout.bounds
    let minimum = Geometry.minSize
    for frame in layout.shownFrames {
        let r = frame.rect
        if r.x < 0 || r.y < 0 || r.x + r.w > bounds.w || r.y + r.h > bounds.h {
            return "shown rect of \(frame.id.text) is outside the bounds"
        }
        if bounds.w >= minimum.w && r.w < minimum.w { return "shown width is below the minimum" }
        if bounds.h >= minimum.h && r.h < minimum.h { return "shown height is below the minimum" }
    }
    return nil
}

private func frameOf(_ layout: WindowLayout, _ id: FrameID) -> LayoutFrame? {
    layout.frames.first { $0.id == id }
}

private func actionRule(
    _ before: WindowLayout, _ action: WindowAction, _ changed: Bool, _ after: WindowLayout
) -> String? {
    switch action {
    case .open(let panel):
        guard let frame = after.frame(of: panel), after.frames.last?.id == frame.id,
            frame.active == panel, !frame.minimised
        else { return "open did not show the panel on top" }
    case .close(let panel):
        if after.frame(of: panel) != nil { return "close left the panel" }
        if changed != (before.frame(of: panel) != nil) { return "close reported a wrong change" }
    case .replace(let panel, let other):
        if panel == other || before.frame(of: panel) == nil {
            if changed { return "replace changed with no good panel" }
        } else if after.frame(of: panel) != nil || after.frame(of: other) == nil {
            return "replace did not swap the panel"
        }
    case .closeActive:
        if changed != (before.topFrame != nil) { return "closeActive reported a wrong change" }
    case .focus(let id):
        if frameOf(before, id) != nil && after.frames.last?.id != id {
            return "focus is not on top"
        }
    case .setRect(let id, let rect):
        let frame = frameOf(before, id)
        let blocked = frame == nil || frame!.locked || frame!.minimised || !finite(rect)
        if blocked && changed { return "setRect changed a locked, minimised or bad frame" }
        if !blocked, let now = frameOf(after, id),
            now.rect != Geometry.clampRect(rect, bounds: before.bounds)
        {
            return "setRect did not clamp the rect"
        }
    case .stack(let id, let target):
        let source = frameOf(before, id)
        let into = frameOf(before, target)
        let blocked =
            id == target || source == nil || into == nil || source!.minimised || into!.minimised
            || source!.locked
        if blocked && changed { return "stack changed with a locked or minimised frame" }
        if !blocked {
            if after.frames.count != before.frames.count - 1 { return "stack kept two frames" }
            let merged = Set(source!.panels + into!.panels)
            if after.frames.last.map({ Set($0.panels) }) != merged { return "stack lost a panel" }
        }
    case .unstack(let panel, let rect):
        let frame = before.frame(of: panel)
        let blocked = frame == nil || frame!.panels.count < 2 || frame!.locked || !finite(rect)
        if blocked && changed { return "unstack changed a bad or locked frame" }
        if !blocked && after.frames.last?.panels != [panel] { return "unstack did not tear out" }
    case .activate(let panel):
        if let frame = after.frame(of: panel), frame.active != panel { return "activate failed" }
    case .minimise(let id):
        if let frame = frameOf(after, id), !frame.minimised { return "minimise failed" }
    case .restore(let id):
        if let frame = frameOf(after, id), frame.minimised || after.frames.last?.id != id {
            return "restore did not show the frame on top"
        }
    case .lock(let id, let locked):
        if let frame = frameOf(after, id), frame.locked != locked { return "lock failed" }
        if let was = frameOf(before, id), changed != (was.locked != locked) {
            return "lock reported a wrong change"
        }
    case .bounds(let size):
        let good = size.w.isFinite && size.h.isFinite && size.w >= 1 && size.h >= 1
        if !good && after.bounds != before.bounds { return "bad bounds were taken" }
        if good && after.bounds != size { return "good bounds were not taken" }
    case .load(let snapshot):
        if !changed { return "load reported no change" }
        if after.memory != snapshot.memory { return "load changed the memory" }
        if after.frames.contains(where: { $0.id.number < before.nextFrame }) {
            return "load reused a frame ID"
        }
    }
    return nil
}

private func finite(_ rect: LayoutRect) -> Bool {
    rect.x.isFinite && rect.y.isFinite && rect.w.isFinite && rect.h.isFinite
}

// A snapshot, then a load into a new layout with the same bounds, keeps the shown layout.
private func roundTripRule(_ layout: WindowLayout) -> String? {
    var copy = WindowLayout(bounds: layout.bounds)
    copy.apply(.load(layout.snapshot))
    func shape(_ list: [LayoutFrame]) -> [[String]] {
        list.map {
            [
                $0.panels.map(\.text).joined(separator: ","), $0.active.text,
                "\($0.rect)", "\($0.minimised)", "\($0.locked)",
            ]
        }
    }
    if shape(copy.shownFrames) != shape(layout.shownFrames) {
        return "a snapshot and a load did not keep the shown layout"
    }
    if copy.memory != layout.memory { return "a snapshot and a load did not keep the memory" }
    return nil
}

@Suite("the window layout, random runs")
struct WindowLayoutPropertyTests {
    @Test("500 seeded runs keep the layout rules after each action")
    func rules() {
        var total = 0
        for run in 0..<runCount {
            var source = Source(rng: SplitMix64(state: seed &+ UInt64(run)))
            var layout = WindowLayout(bounds: LayoutSize(w: 1200, h: 800))
            var done: [WindowAction] = []
            for _ in 0..<source.int(1...maxActions) {
                let action = source.action(layout)
                done.append(action)
                let before = layout
                let changed = layout.apply(action)
                total += 1
                if let rule = broken(before, action, changed, layout) {
                    Issue.record(
                        """
                        \(rule). Replay: seed \(seed) + run \(run) (state \(seed &+ UInt64(run))), \
                        step \(done.count). Actions: \(done)
                        """)
                    return
                }
            }
        }
        #expect(total > 5000)
    }
}
