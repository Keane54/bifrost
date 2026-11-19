import Foundation

// The paths of the state that Bifrost shares with Claude Code, under one home: the socket of the
// Live details mod, the mod folder, the skills folder, the settings file of Claude Code, the
// backups of that file, the saved status line of the user, the dot folder of Bifrost and the
// folders of Reviews, the Daily update and the hand-over notes.
//
// Bifrost Dev owns these paths (user decision, 2026-11-16; the section "Files on disk" of the
// architecture design). The home is the resolved home (StartPlan.sharedHome), so a test home has
// its own shared paths under the test home. Only the start code of the app module makes this
// value (forbidden rule shared-state). Each other file gets the paths from
// AppServices.sharedState. The type is in this module, so each feature module can take it.
//
// This type is separate from the data folders of the app, so the paths of the app never point to
// this state by accident. It takes only a home folder, never an AppIdentity, and it never gives a
// path in Library/Application Support.
package struct SharedClaudeState: Sendable, Equatable {
    // <home>/.bifrost/live.sock: the socket that the mod sends its lines to.
    package let liveSocket: URL
    // <home>/.bifrost/mod: the folder of the mod.
    package let modFolder: URL
    // <home>/.bifrost/skills: the folder that the skills plugin reads.
    package let skillsFolder: URL
    // <home>/.claude/settings.json: the settings file of Claude Code.
    package let claudeSettings: URL
    // <home>/.bifrost/backups: the copies of the settings file of Claude Code before an edit.
    package let backups: URL
    // <home>/.bifrost/statusline-original.json: the status line of the user before Bifrost
    // changed it.
    package let savedStatusLine: URL
    // <home>/.bifrost: the dot folder of Bifrost, with the old hook data.
    package let bifrostHome: URL
    // <home>/.bifrost/reviews: the state, the clones and the worktrees of Reviews.
    package let reviewsFolder: URL
    // <home>/.bifrost/daily-update: the settings and the drafts of the Daily update.
    package let dailyUpdateFolder: URL
    // <home>/.bifrost/handovers: the hand-over notes of the sessions.
    package let handoversFolder: URL

    // Each file path is a file URL with no "/" at its end. The init gives the kind of each path,
    // so it reads no file: a folder at the path of a file does not add a "/" to the texts that
    // name the path.
    package init(home: URL) {
        let bifrost = home.appendingPathComponent(".bifrost", isDirectory: true)
        liveSocket = bifrost.appendingPathComponent("live.sock", isDirectory: false)
        modFolder = bifrost.appendingPathComponent("mod", isDirectory: true)
        skillsFolder = bifrost.appendingPathComponent("skills", isDirectory: true)
        claudeSettings = home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        backups = bifrost.appendingPathComponent("backups", isDirectory: true)
        savedStatusLine = bifrost.appendingPathComponent(
            "statusline-original.json", isDirectory: false)
        bifrostHome = bifrost
        reviewsFolder = bifrost.appendingPathComponent("reviews", isDirectory: true)
        dailyUpdateFolder = bifrost.appendingPathComponent("daily-update", isDirectory: true)
        handoversFolder = bifrost.appendingPathComponent("handovers", isDirectory: true)
    }
}
