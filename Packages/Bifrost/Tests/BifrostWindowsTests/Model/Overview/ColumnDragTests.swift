import BifrostWindows
import Testing

// The drop place of a dragged header (the section "Tabs and columns" of
// docs/behaviour/overview.md).

private let columns: [OverviewColumn] = [.kind, .name, .state, .cost]

@Suite("column drag")
struct ColumnDragTests {
    // A drop on a header to the right puts the column after that header. A drop on a header to
    // the left puts it before that header.
    @Test func aDropGoesAfterAHeaderOnTheRightAndBeforeAHeaderOnTheLeft() {
        #expect(ColumnDrag.dropBefore(columns, from: .name, to: .state) == .some(.cost))
        #expect(ColumnDrag.dropBefore(columns, from: .name, to: .cost) == .some(nil))
        #expect(ColumnDrag.dropBefore(columns, from: .cost, to: .name) == .some(.name))
        #expect(ColumnDrag.dropBefore(columns, from: .cost, to: .kind) == .some(.kind))
    }

    @Test func theKindColumnTheSameColumnAndAHiddenColumnDoNotMove() {
        #expect(ColumnDrag.dropBefore(columns, from: .kind, to: .name) == nil)
        #expect(ColumnDrag.dropBefore(columns, from: .name, to: .name) == nil)
        #expect(ColumnDrag.dropBefore(columns, from: .model, to: .name) == nil)
        #expect(ColumnDrag.dropBefore(columns, from: .name, to: .model) == nil)
    }

    // A drop on the kind header puts the column directly after the kind column.
    @Test func aDropOnTheKindHeaderMovesTheColumnToAfterKind() throws {
        var config = OverviewConfig.standard
        let tab = config.tabs[0]
        let before = try #require(
            ColumnDrag.dropBefore(tab.columns, from: .project, to: .kind))
        config.apply(.moveColumn(tab.id, .project, before: before))
        #expect(config.tabs[0].columns == [.kind, .project, .name, .state, .activity])
    }
}
