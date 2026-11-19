// The timeline of the debug bench and its safety rules. The timeline comes
// from the prototype gate (docs/archive/gates/integrated-prototype). A bench run uses only a test
// home and the fake claude: the claude on the PATH of the app must resolve to
// scripts/fake-claude/claude.
//
// Safety: no test here starts a bench run, opens a window or runs a program. The refusal tests
// only make a runner, and the file tests only read paths.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostLayout

@MainActor
@Suite("bench plan", .timeLimit(.minutes(1)))
struct BenchPlanTests {
    // The prototype timeline: start 10 s, quiet 4, idle 12, warm 6, stream 12, drag 12, resize
    // 8, typeprep 3 and typing 25. The prototype step "end" (1 s) only waited for the quit of the
    // gate app, so the bench drops it.
    @Test func theGatePlanHasThePrototypeTimeline() {
        let timeline: [(BenchPhase, Int)] = [
            (.start, 10), (.quiet, 4), (.idle, 12), (.warm, 6), (.stream, 12), (.drag, 12),
            (.resize, 8), (.typeprep, 3), (.typing, 25),
        ]
        let steps = timeline.map { BenchPlan.Step(phase: $0.0, time: .seconds($0.1)) }
        #expect(BenchPlan.gate.steps == steps)
        #expect(BenchPlan.gate.total == .seconds(92))
        #expect(BenchPhase(rawValue: "end") == nil)
        // The short plan of Step 4 has each phase of the gate plan, in the same order, and 30 s.
        #expect(BenchPlan.short.steps.map(\.phase) == BenchPlan.gate.steps.map(\.phase))
        #expect(BenchPlan.short.total == .seconds(30))
        #expect(BenchPlan.short.steps.allSatisfy { $0.time >= .seconds(2) })
        // The plan names of the test port.
        #expect(BenchPlan(TestBench.Plan.gate) == .gate)
        #expect(BenchPlan(TestBench.Plan.short) == .short)
    }

    // The path of the drag: 420 by 220 points, and of the resize: 180 by 120 points (the
    // benchmark path of the prototype). Each is a sum of sine waves of the phase time.
    @Test func theDragAndTheResizeFollowThePrototypePath() {
        #expect(BenchPath.drag(at: 0) == BenchPath.Offset(x: 0, y: 0))
        let quarter = BenchPath.drag(at: 1)
        #expect(abs(quarter.x - 420) < 1e-9)
        #expect(abs(quarter.y - 220 * sin(2 * Double.pi / 3)) < 1e-9)
        let resize = BenchPath.resize(at: 0.75)
        #expect(abs(resize.x - 180) < 1e-9)
        #expect(abs(resize.y - 120 * sin(2 * Double.pi * 0.75 / 2.5)) < 1e-9)
        // The largest offsets in each direction, at each display frame of 12 s at 120 Hz.
        let times = (0..<1440).map { Double($0) / 120 }
        #expect(abs((times.map { BenchPath.drag(at: $0).x }.max() ?? 0) - 420) < 0.01)
        #expect(abs((times.map { BenchPath.drag(at: $0).y }.min() ?? 0) + 220) < 0.01)
        #expect(abs((times.map { BenchPath.resize(at: $0).y }.max() ?? 0) - 120) < 0.01)
    }

    // The chats open in the 8 slots of the prototype layout: 520 x 500 in two rows of 4, 440 and
    // 454 apart, so each frame overlaps its neighbours. A smaller canvas scales the slots down.
    @Test func theSlotsOfThePrototypeLayoutOverlapAndFitTheCanvas() {
        let full = BenchRunner.slots(in: LayoutSize(w: 1900, h: 1000))
        #expect(full.count == 8)
        #expect(full[0] == LayoutRect(x: 16, y: 16, w: 520, h: 500))
        #expect(full[5] == LayoutRect(x: 456, y: 470, w: 520, h: 500))
        #expect(full[7] == LayoutRect(x: 1336, y: 470, w: 520, h: 500))
        #expect(full[1].x < full[0].x + full[0].w)
        #expect(full[4].y < full[0].y + full[0].h)
        let small = BenchRunner.slots(in: LayoutSize(w: 936, h: 986))
        #expect(small[0] == LayoutRect(x: 8, y: 8, w: 260, h: 250))
        #expect(small.allSatisfy { $0.x + $0.w <= 936 && $0.y + $0.h <= 986 })
    }

    // A bench run needs a test home. With no test home there is no runner.
    @Test func theBenchRefusesWithoutATestHome() throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        let fake = try Repo.fakeClaude()
        #expect(BenchRunner(testHome: nil, claudePath: fake, fakeClaudePath: fake) == nil)
        let runner = BenchRunner(
            testHome: URL(fileURLWithPath: home.path), claudePath: fake, fakeClaudePath: fake)
        #expect(runner != nil)
    }

    // The claude that the app runs must resolve to the fake claude. A copy of the fake in
    // another folder, another program and a path with no file are refused. A link to the fake
    // resolves to the fake.
    @Test func theBenchRefusesAClaudeThatIsNotTheFake() throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        let testHome = URL(fileURLWithPath: home.path)
        let fake = try Repo.fakeClaude()
        let copy = home.appending("claude")
        try FileManager.default.copyItem(atPath: fake, toPath: copy)
        let link = home.appending("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fake)
        for other in [copy, "/usr/bin/true", home.appending("missing"), ""] {
            let runner = BenchRunner(testHome: testHome, claudePath: other, fakeClaudePath: fake)
            #expect(runner == nil, "\(other)")
        }
        #expect(BenchRunner(testHome: testHome, claudePath: link, fakeClaudePath: fake) != nil)
        // A fake path with no file matches nothing, also not the same path.
        let missing = home.appending("missing")
        #expect(
            BenchRunner(testHome: testHome, claudePath: missing, fakeClaudePath: missing) == nil)
    }

    // The results go only to <test home>/bench/<name>.jsonl, with a name of the test port form.
    @Test func theBenchWritesOnlyIntoTheBenchFolderOfTheTestHome() throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        let testHome = URL(fileURLWithPath: home.path)
        let fake = try Repo.fakeClaude()
        let runner = try #require(
            BenchRunner(testHome: testHome, claudePath: fake, fakeClaudePath: fake))
        let bench = testHome.appending(path: "bench")
        #expect(runner.allows(bench.appending(path: "run-1.jsonl")))
        let refused = [
            testHome.appending(path: "run.jsonl"), bench.appending(path: "run.json"),
            bench.appending(path: "Run.jsonl"), bench.appending(path: "a/run.jsonl"),
            bench.appending(path: "../run.jsonl"), bench.appending(path: ".jsonl"),
            URL(fileURLWithPath: "/tmp/bench/run.jsonl"),
        ]
        for output in refused {
            #expect(!runner.allows(output), "\(output.path)")
        }
    }

    // A sample has the start of its phase: the host time (the clock of mach_absolute_time, as
    // CACurrentMediaTime) and the wall time. run.sh --trace puts each hitch of Instruments in its
    // phase with them.
    @Test func aSampleHasTheStartOfItsPhase() throws {
        let sample = BenchSample(
            phase: "drag", seconds: 12, frames: 1440, missed: 0, excludedSeconds: 0,
            appFootprint: 1, childFootprint: 2, appInstructions: 3, appCPUSeconds: 4,
            start: 51234.5, startDate: 1_795_300_000.25)
        let data = try JSONEncoder().encode(sample)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["start"] as? Double == 51234.5)
        #expect(object["startDate"] as? Double == 1_795_300_000.25)
        #expect(try JSONDecoder().decode(BenchSample.self, from: data) == sample)
    }
}
