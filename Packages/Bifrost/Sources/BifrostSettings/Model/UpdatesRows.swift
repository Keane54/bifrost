// The rows of Settings > Updates (docs/behaviour/updates.md, "Settings > Updates"). This file is
// the one source of the labels: each row shows its label, and the search finds a row by it.
import BifrostSessions
import Foundation

// The rows of the section, in order. The raw value is the label of the row.
package enum UpdatesRow: String, Sendable, CaseIterable {
    // The setting of the automatic checks.
    case auto = "Check for updates automatically"
    case version = "Version"
    case lastCheck = "Last checked"
    case checkNow = "Check for updates"
    case releaseNotes = "Release notes"
}

package enum UpdatesRows {
    // The text under Check for updates while the button is off.
    package static let offReason = "This build doesn't update itself."
    // The text of Version when the app has no version.
    package static let noVersion = "Unknown"
    // The text of Last checked before the first check.
    package static let notYetChecked = "Not yet"
    // The label of the buttons.
    package static let checkNowButton = "Check now"
    package static let releaseNotesButton = "Open"

    // The text under Check for updates while a check runs.
    package static let checkingLine = "Checking for updates…"
    // The text of the Version row.
    package static func versionText(_ version: String?) -> String {
        guard let version, !version.isEmpty else { return noVersion }
        return version
    }

    // The text of Last checked: the clock for a check of today, else the day, the date and the
    // clock, for example "Tue 10 Nov 09:07". nil: no check yet.
    package static func lastCheckText(
        _ date: Date?, now: Date, zone: TimeZone = .current
    ) -> String {
        guard let date else { return notYetChecked }
        return TimeText.when(date.millisecondsSince1970, now: now.millisecondsSince1970, zone: zone)
    }
}
