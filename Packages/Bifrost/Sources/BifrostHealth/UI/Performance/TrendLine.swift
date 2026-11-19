// The trend line of the section "Bifrost" of the Performance panel (docs/behaviour/health.md,
// "The panel"): the memory and the CPU of Bifrost with its chat terminals in the last 10 minutes,
// or since the start when Bifrost ran for less time. The line goes from the oldest sample at the
// left edge to the newest sample at the right edge, so a short trend also fills the width. The
// key under the line names the two lines and the time that they show.
import BifrostLook
import SwiftUI

// The points of the two lines in a box.
package enum TrendGeometry {
    // The memory line shows at least this range, so a small change does not fill the height.
    package static let minimumMemorySpan = 64.0 * 1_048_576
    // The CPU line shows 0 to at least 100 % of one core.
    package static let minimumCPUTop = 100.0

    // The points of the memory line and of the CPU line in a box of the size, with the padding
    // at the top and at the bottom. The memory line uses its own range. The CPU line starts at 0.
    // One sample is one point at the right edge.
    package static func lines(
        _ trend: [Sample], in size: CGSize, padding: CGFloat
    ) -> (memory: [CGPoint], cpu: [CGPoint]) {
        guard let first = trend.first, let last = trend.last else { return ([], []) }
        let span = (last.at - first.at) / .seconds(1)
        let x = { (sample: Sample) -> CGFloat in
            span > 0 ? CGFloat((sample.at - first.at) / .seconds(1) / span) * size.width
                : size.width
        }
        let memories = trend.map { Double($0.use.total.memory) }
        var low = memories.min() ?? 0
        var high = memories.max() ?? 0
        if high - low < minimumMemorySpan {
            let middle = (low + high) / 2
            low = middle - minimumMemorySpan / 2
            high = middle + minimumMemorySpan / 2
        }
        let cpuTop = max(minimumCPUTop, trend.map(\.use.total.cpu).max() ?? 0)
        let inner = size.height - 2 * padding
        let y = { (value: Double, low: Double, high: Double) -> CGFloat in
            size.height - padding - CGFloat((value - low) / (high - low)) * inner
        }
        let memory = trend.map {
            CGPoint(x: x($0), y: y(Double($0.use.total.memory), low, high))
        }
        let cpu = trend.map { CGPoint(x: x($0), y: y($0.use.total.cpu, 0, cpuTop)) }
        return (memory, cpu)
    }
}

struct TrendLine: View {
    let trend: [Sample]
    let style: PanelStyle

    var body: some View {
        let memoryWidth = style.points(1.5)
        let cpuWidth = style.points(1)
        let padding = style.points(2)
        VStack(alignment: .leading, spacing: style.points(4)) {
            Canvas { context, size in
                let lines = TrendGeometry.lines(trend, in: size, padding: padding)
                context.stroke(
                    path(lines.cpu), with: .color(PerformanceColours.cpuLine.color),
                    lineWidth: cpuWidth)
                context.stroke(
                    path(lines.memory), with: .color(PerformanceColours.memoryLine.color),
                    lineWidth: memoryWidth)
            }
            .frame(height: style.points(34))
            .accessibilityHidden(true)
            HStack(spacing: style.points(12)) {
                key("Memory", PerformanceColours.memoryLine)
                key("CPU", PerformanceColours.cpuLine)
                Text(PerformanceText.trendKey(trend))
            }
            .font(style.font(10))
            .foregroundStyle(style.dim)
        }
        .padding(.top, style.points(2))
        .padding(.bottom, style.points(4))
    }

    // The line through the points. One point gives a short mark at the right edge.
    private func path(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            if points.count == 1 {
                path.move(to: CGPoint(x: first.x - style.points(2), y: first.y))
                path.addLine(to: first)
                return
            }
            path.addLines(points)
        }
    }

    // One item of the key: a short line in the colour, then the name.
    private func key(_ name: String, _ colour: TokenColour) -> some View {
        HStack(spacing: style.points(4)) {
            Rectangle().fill(colour.color)
                .frame(width: style.points(12), height: style.points(2))
                .accessibilityHidden(true)
            Text(name)
        }
    }
}
