// The columns of an Overview table. The order of the cases is the default order of the columns.
// The raw value is the name of the column in the saved config. The type is public because the
// sort request of the debug test port has a column.
public enum OverviewColumn: String, Sendable, CaseIterable {
    case kind, name, priority, state, project, branch, model, context, cost, activity

    // The visible columns of a new tab. The user turns on the other columns in the Overview
    // Settings panel.
    package static let defaultVisible: [OverviewColumn] = [
        .kind, .name, .state, .project, .activity,
    ]

    // The limits of a column width, in layout units.
    package static let minWidth = 24.0, maxWidth = 600.0

    // The text of the header. The kind column has no text.
    package var label: String {
        switch self {
        case .kind: ""
        case .name: "Name"
        case .priority: "Priority"
        case .state: "State"
        case .project: "Project"
        case .branch: "Branch"
        case .model: "Model"
        case .context: "Context %"
        case .cost: "Cost"
        case .activity: "Activity"
        }
    }

    // The width of a column that has no saved width, in layout units. A character of the table
    // font is 0.6 em wide: 7.2 units at 12 units. A width holds the normal content of its column
    // (a name of 24 characters, a project of two path parts) and its header. The Cost width
    // holds a cost of three digits with the mark, for example ≈$123.45.
    package var defaultWidth: Double {
        switch self {
        case .kind: 28
        case .name: 184
        case .priority: 76
        case .state: 84
        case .project: 200
        case .branch: 130
        case .model: 90
        case .context: 84
        case .cost: 68
        case .activity: 112
        }
    }

    // True when the first click on the header sorts from the highest value.
    package var sortsDescendingFirst: Bool {
        switch self {
        case .context, .cost, .activity: true
        case .kind, .name, .priority, .state, .project, .branch, .model: false
        }
    }

    // The width rounded to a whole unit and kept in the limits. A half rounds up.
    package static func clamp(width: Double) -> Double {
        min(maxWidth, max(minWidth, width.rounded()))
    }
}
