# Deliberate differences

This table lists the places where the native release notes, What's new and Settings > Updates work
differently from the Electron app on purpose. That code (`src/main/release-notes/`,
`src/main/updates/`, `release-notes/` and `UpdatesSection.tsx` in `src/renderer/src/`) is the
reference for what the dialog and the section decide, not for how they get there. The last column
says whether you'd notice the difference in normal use, and a row marked "for the hands-on test" is
one to check by hand in the real app.

The rules themselves match: the order of versions, which sections show and under which names, the
ten-minute cache, the limits of the request, and the What's new decision. A few parts look
different and give the same result: the dialog is one of the window's own dialogs where the
Electron app used a Base UI dialog, two dialogs that open at once share one task where the
TypeScript shared one promise, and a release is a value of `Release` with a `Date` and a `URL`
where the TypeScript passed an ISO text and a string.

| ID | Where | TypeScript | Swift | Reason | Visible? |
| --- | --- | --- | --- | --- | --- |
| RN1 | The update states and the Update button | Settings > Updates shows a state line ("Checking for updates…", "Downloading Bifrost 1.2.0 (40%)…", "You're up to date.", a failure text), buttons for Restart to update, Try again and Show log, and the side bar has an Update button. | Sparkle's standard window shows an available update, its progress and its errors. Settings > Updates has the version, the last check and "Check now" (off while the updater doesn't run). There is no state line, no log button and no Update button in the side bar. | Sparkle already has a complete, tested interface for these states, and a second one in Bifrost would show the same facts twice. | Yes. Checked at the first real update from the Electron app. |
| RN2 | The address of the releases | The owner and the name of the repository are constants in the code (`UPDATE_OWNER`, `UPDATE_REPO`). | The Releases page is the build setting `BIFROST_RELEASES_URL`, which gives the Info.plist key `BifrostReleasesURL`. The address of the API and the check of each release page follow from it. | No name of a person or a project stays in the code, and a fork changes one build setting. | No. |
| RN3 | The notes of an available update | Settings > Updates names the new version in its state line. The notes show only in the Release notes dialog, and in What's new after the update. | Sparkle's update window shows the notes of the new version before you install it: the summary and the sections, as Markdown. The release workflow puts the release notes into the appcast item (`scripts/release/appcast.sh`). | Sparkle's window already has a place for the notes, and the appcast carries the same notes as the GitHub release, so you see what changed before you install. | Yes, for the hands-on test. |
