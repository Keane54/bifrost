// What's new at the start (docs/behaviour/updates.md, "What's new"): the rule that decides if the
// dialog opens by itself, and the releases that it shows.

// The versions of a What's new dialog: the releases after `since`, up to and including `version`.
// since is nil for the first version with What's new: the dialog then shows only `version`.
package struct WhatsNewRange: Sendable, Equatable {
    package var since: ReleaseVersion?
    package var version: ReleaseVersion

    package init(since: ReleaseVersion?, version: ReleaseVersion) {
        self.since = since
        self.version = version
    }

    // The releases of the list that the dialog shows, in the order of the list.
    package func releases(in list: [Release]) -> [Release] {
        list.filter { release in
            guard release.version <= version else { return false }
            guard let since else { return release.version == version }
            return release.version > since
        }
    }
}

package enum WhatsNewRule {
    // The decision at the start. current is the version of the running app. lastSeen is the
    // version of the last What's new, or of the first start, and nil when none is stored. A stored
    // text that is not a version counts as none. setupDone is true after the Setup dialog got a
    // choice.
    // - open: the range to show, or nil.
    // - store: true when the current version must become the last seen version. The app stores
    //   it before the dialog opens, so a failed load never opens it again for the same version.
    package static func decide(
        current: String, lastSeen: String?, setupDone: Bool
    ) -> (open: WhatsNewRange?, store: Bool) {
        guard let version = ReleaseVersion(current) else { return (nil, false) }
        guard let seen = lastSeen.flatMap(ReleaseVersion.init) else {
            // No setup choice: a fresh install, which has no news. An existing user who updates
            // to the first version with What's new gets the notes of that version.
            return (setupDone ? WhatsNewRange(since: nil, version: version) : nil, true)
        }
        if seen < version { return (WhatsNewRange(since: seen, version: version), true) }
        return (nil, false)
    }
}
