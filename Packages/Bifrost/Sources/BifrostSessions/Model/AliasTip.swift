// The tooltip of the name of a row in the Selected Item panel. A row with a local name gives the
// Claude Code name. Another row gives the name itself, so a name that the panel cuts can be read.
package func aliasTip(_ row: SessionRow) -> String {
    row.name == row.claudeName ? row.name : "Claude Code name: \(row.claudeName)"
}
