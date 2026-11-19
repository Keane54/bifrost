// The values of the Performance panel that have no view (docs/behaviour/health.md, "The panel"):
// the colours, the choice of the Details row in the UI state, and what the headline shows.
import BifrostFoundation
import BifrostLook

// The colours of the panel and of the dot of its side bar button.
package enum PerformanceColours {
    // The colour of a level: green for OK, amber for Warning, red for Problem.
    package static func level(_ level: HealthLevel) -> TokenColour {
        switch level {
        case .ok: ThemeTokens.ctxLow
        case .warning: ThemeTokens.ctxMid
        case .problem: ThemeTokens.ctxHigh
        }
    }

    // The lines of the trend have colours with no meaning of a level: the memory line is amber
    // (tab-8) and the CPU line is blue (icon-5), as the approved mockup has them.
    package static let memoryLine = ThemeTokens.tabs[7]
    package static let cpuLine = ThemeTokens.icons[4]

    // The colour of the memory pressure and of its bar, or nil.
    package static func pressure(_ pressure: MemoryPressure?) -> TokenColour? {
        switch pressure {
        case .normal: ThemeTokens.ctxLow
        case .warning: ThemeTokens.ctxMid
        case .critical: ThemeTokens.ctxHigh
        case nil: nil
        }
    }
}

// The value of the panel in the UI state (ui-state.json, "performance"): {"detailsOpen": true}
// while the Details row is open. The form is the form of the Electron app. The other fields of
// the value stay.
package enum PerformanceDetails {
    static let key = "detailsOpen"

    // True only for an object with detailsOpen true. Closed is the default.
    package static func isOpen(_ value: JSONValue?) -> Bool {
        value?.object?[key] == .bool(true)
    }

    // The value with detailsOpen set to open. A value that is not an object becomes an object.
    package static func value(_ open: Bool, in value: JSONValue?) -> JSONValue {
        var fields = value?.object ?? [:]
        fields[key] = .bool(open)
        return .object(fields)
    }
}

// What the headline of the panel shows.
package enum PerformanceHeadline: Equatable {
    // No data and no reason: "Checking Bifrost…" in the dim colour, with no square.
    case checking
    // OK, with the text that gives the measured values.
    case ok(String)
    // Warning or Problem, with one item for each reason, the problems first.
    case reasons(HealthLevel, [ReasonItem])

    package init(_ snapshot: PerformanceSnapshot) {
        switch snapshot.level {
        case nil: self = .checking
        case .some(.ok): self = .ok(snapshot.headline)
        case .some(let level):
            let items = snapshot.reasons.map {
                ReasonItem(text: $0.text, colour: PerformanceColours.level($0.level))
            }
            self = .reasons(level, items)
        }
    }
}

// One reason of the headline: its text and the colour of its square.
package struct ReasonItem: Equatable {
    package var text: String
    package var colour: TokenColour
}
