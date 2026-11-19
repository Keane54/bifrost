# Releasing Bifrost

A release of Bifrost is a signed, notarised build of the app, published on the Releases page of the
Bifrost repo on GitHub together with the files that let installed copies update themselves. The
Release workflow (`.github/workflows/release.yml`) builds it on GitHub macOS runners, and a person
starts it by hand. This page explains how a release runs, how the first native release takes over
from the Electron app (the bridge), how that handover is checked, and which steps are still left
for you and for the cutover commit.

These workflows only run once the native code has replaced the Electron code in the Bifrost repo.
Until then they wait here, ready for that commit.

## What a release publishes

Each release publishes four files:

| File | What it's for |
| --- | --- |
| `Bifrost-arm64.dmg` | A manual install. The name has no version, so the README link `https://github.com/Keane54/bifrost/releases/latest/download/Bifrost-arm64.dmg` always gets the newest DMG. |
| `Bifrost-<version>-arm64-mac.zip` | The update archive. Both updaters download this same file: the Electron app's updater and Sparkle in the native app. |
| `latest-mac.yml` | The update feed that the Electron app reads. |
| `appcast.xml` | The update feed that the native app reads. |

Later native releases carry the Electron feed and the ZIP as well. An Electron copy that's switched
off during the first native release looks at whichever release is newest when it next checks, so
the Electron feed has to stay for as long as an Electron copy might still be out there.

## Versions

semantic-release picks the version from the commits since the last tag, with the rules in
`.releaserc.json`. A breaking change gives a new major version, `feat` a new minor version, and
`fix`, `perf`, `revert`, `docs`, `style`, `chore`, `refactor`, `test`, `build` and `ci` a patch.
Any other type, and a merge commit, gives no release. A commit counts as breaking when its type has
a `!` (`feat!: ...`) or its message has a `BREAKING CHANGE:` footer. The tags have the form
`v1.2.3`.

The first native release is 1.0.0 (user decision, 2026-11-18), and nothing hard-codes that number.
The last Electron release is v0.9.0, and the cutover commit is a breaking change, so
semantic-release goes from 0.9.0 to 1.0.0 by its normal rules. After that, a fix gives 1.0.1, a
feature 1.1.0 and the next breaking change 2.0.0. So the cutover commit message must have both the
`!` and the footer, like this:

```text
feat!: replace the Electron app with the native app

BREAKING CHANGE: Bifrost is now a native macOS app.
```

The app's version (`CFBundleShortVersionString`) and its build number (`CFBundleVersion`) are both
the semantic-release version, for example 1.0.1. Sparkle decides whether an update is newer by
comparing `CFBundleVersion` with the version in the appcast, and its standard comparator orders
dotted versions, so the build number always rises with the version and there's no second number to
keep in step.

## How a release runs

Start a release from Actions > Release > Run workflow on `main`, or with the GitHub CLI:

```sh
gh workflow run release.yml -R Keane54/bifrost -f mode=dry-run -f summary="<text>"
```

Use `-f mode=release` for a real release. The summary is required in both modes. It can have at
most 600 characters, and no line can start with `#`, because the release notes use `#` for their
headings. It goes at the top of the release notes, where the app's What's new dialog and Sparkle's
update window both show it (`scripts/release/summary.sh` checks it).

The workflow has three jobs, and they're split for one reason: no third-party build code ever runs
next to the signing keys. Building the app runs code from its Swift packages, including SwiftTerm's
build plug-in, and on a GitHub runner any step of a job can reach every secret that job holds. So
the job that builds has no secrets at all, and the job that holds the secrets builds nothing.

1. **Check** runs on a cheap Linux runner. It checks the summary, checks that CI passed for the
   commit at the top of `main`, and asks semantic-release for the next version in a dry run. The
   dry run also writes the full release notes, the summary followed by the notes of the commits, to
   `.release-notes.md` (`scripts/release/save-notes.sh`). When no commit since the last release
   needs a new version, the run stops there and no macOS runner starts. The dry run stays in this
   job because semantic-release checks that it could push a tag even in a dry run, and the build
   job's token can only read.
2. **Build** runs on a `macos-26` runner with no environment, no secrets and a read-only token. It
   checks that `main` hasn't moved, builds the Release app with the version from the check job,
   checks its Sparkle settings, and uploads the unsigned app as a workflow artifact together with
   the version and the release notes. The app goes into a `ditto` ZIP first, because an artifact
   doesn't keep the symbolic links and file modes inside `Sparkle.framework`.
3. **Sign** runs on a fresh `macos-26` runner in the `release` environment, which holds the signing
   secrets and only allows `main`. It checks that `main` hasn't moved, downloads the artifact and
   checks its version, and treats the app as data: nothing inside it ever runs. It fetches Sparkle's
   tools (see below), downloads the app of the last Electron release for the bridge check, builds a
   temporary keychain from the Developer ID certificate, and runs `scripts/release/prepare.sh` to
   sign the app and make the release files. Then it deletes the keychain and the notarisation key,
   and in release mode runs semantic-release, which only publishes.

`scripts/release/build-app.sh` builds the app in the build job. It adds the `BIFROST_CUTOVER`
compile condition on the `xcodebuild` command line only, so the published app is allowed to start
while a Release build from the build configuration alone still refuses to, and the rules check that
keeps the condition out of the build configuration stays valid. Xcode asks a person once to trust
each build plug-in of a Swift package, which a runner can't answer, so in CI (where GitHub sets
`CI=true`) both `build-app.sh` and `scripts/check.sh` pass `-skipPackagePluginValidation`. On a Mac
the prompt stays.

`prepare.sh` makes the files in the sign job, with one script for each step in `scripts/release/`:

1. `check-sparkle.sh` checks the Sparkle settings in the app: the feed address and the full public
   key.
2. `sign-app.sh` signs the app from the inside out with the hardened runtime: Sparkle's XPC
   services, its `Autoupdate` tool and `Updater.app`, the Sparkle framework, any other code, and
   last the app with its one entitlement, audio input. `codesign --deep` would sign every nested
   item the same way, so the script never uses it.
3. `notarise.sh` sends the app to Apple's notary service with `notarytool` and staples the ticket,
   and `verify-app.sh` then checks the signatures, the team, the hardened runtime, the
   entitlements, the version, the ticket and Gatekeeper.
4. `ditto -c -k --sequesterRsrc --keepParent` makes the update ZIP, and `bridge-check.sh` runs the
   bridge check on it (see below).
5. `make-dmg.sh` makes the DMG and signs it, and `notarise.sh` notarises and staples it too.
6. `latest-mac.sh` writes `latest-mac.yml`. `sparkle-sign.sh` signs the ZIP with the Sparkle
   private key and checks that signature against the public key inside the app, and `appcast.sh`
   writes `appcast.xml` with the release notes as the item's description.

Before any of that, `prepare.sh` checks that the app's version is the version it was given, so it
never signs the wrong build.

semantic-release then runs for real in the sign job, with only the GitHub token. It works out the
version and the notes again, and its exec plugin runs `check-dist.sh` as the prepare step, which
checks that `dist/` holds the files of exactly that version. If anything changed since the check
job, the release stops before the tag. Otherwise semantic-release pushes the tag and its github
plugin publishes the release with the four files. No commit goes back to `main`. The text of the
GitHub release comes from this run and the appcast's text from the dry run, both made from the same
commits and summary, so they only differ if the date in the heading changes in between.

The exec plugin passes the release notes to `save-notes.sh` as base64, so the text of a commit
message never reaches the shell as code.

A dry run goes through the same three jobs, with the next version, or the last one when no release
is due. Its notes are the full notes of the dry run, or only the summary when no release is due. It
keeps the files as a download on the workflow run for seven days, and makes no tag and no release.
Start with a dry run before each release, and never skip it before the first native one.

### How the sign job gets Sparkle's tools

`sign_update` reads the Sparkle private key, so the sign job must never run a copy that a build
could have touched, which is why it restores no cache. `scripts/release/sparkle-tools.sh` writes a
throwaway package whose only dependency is Sparkle at the exact version pinned in the project's
`Package.resolved`, and resolves it with `swift package resolve`. That fetches Sparkle's source and
its binary artifact and checks the artifact against the checksum in Sparkle's manifest, and no
other package, SwiftTerm included, comes into the job. A resolve builds nothing and runs no
plug-in: SwiftPM only runs build plug-ins during a build and command plug-ins through
`swift package <command>`, and Sparkle's package has no plug-ins anyway, just one binary target.
The script then checks that SwiftPM resolved the pinned revision, so a moved tag stops the release.
`prepare.sh` insists on being told where the tools are (`SPARKLE_BIN`), so it never falls back to
the copy in `.build/spm`.

## The bridge

The installed Electron copies update with electron-updater 6.8.11, which hands the install to
Squirrel.Mac. They read `latest-mac.yml` of the newest release on GitHub, download the ZIP it
names, check its size and its SHA-512 hash, and hand it to Squirrel.Mac. Squirrel.Mac unpacks the
ZIP, takes the app inside that has the same bundle ID as the running app, and installs it only if
it meets the running app's designated code requirement: in practice, the same bundle ID signed by
the same Developer ID team. The native release app has the Electron app's bundle ID and is signed
by the same team, so the first native release is the bridge on its own, and no extra Electron
release is needed.

The bridge must never reach a Mac older than macOS 26 (user decision, 2026-11-15), and
`latest-mac.yml` says so in `minimumSystemVersion`. electron-updater compares that value with the
Darwin kernel version (`os.release()`) rather than the macOS version, and macOS 26.0 is Darwin
25.0.0, so the feed says `25.0.0`. Writing `26.0` wouldn't work, because it isn't a
semver version and electron-updater quietly skips the check, and `26.0.0` would block macOS 26 too.
A Mac on an older macOS keeps the Electron app until it's on macOS 26, and then needs one manual
install of the DMG.

After the bridge, the native app updates itself with Sparkle 2. It reads `appcast.xml` of the
newest release (`SUFeedURL`, which is `releases/latest/download/appcast.xml`), and before it
installs an update it checks the ZIP's EdDSA signature against the public key built into the app
(`SUPublicEDKey`). Both values come from `Config/Release.xcconfig`, and `UpdatePolicy` only turns
Sparkle on in the release app when both are there.

## The bridge check

The bridge check takes the place of a rehearsal with two test releases (user decision,
2026-11-18), because with two users, two test releases cost more than a failed update does. It has
three steps.

1. CI compares the code requirements. Every release and every dry run downloads the update ZIP
   of the last Electron release (`BRIDGE_FROM_TAG` in `release.yml`, now `v0.9.0`), checks that it
   really holds an Electron app (`electron-app.sh`), and reads that app's designated requirement
   with `codesign`. Then it unpacks the new ZIP the way Squirrel.Mac does and checks the app inside
   against that requirement with `codesign --verify --deep --strict --test-requirement`. The job
   fails if the new app doesn't meet it. This step needs no release.
2. CI builds the update files. It writes the update ZIP and `latest-mac.yml` in the form that
   electron-updater reads. A dry run gives you both to look at.
3. You update your own Mac first. As soon as the release is published, open Electron Bifrost on
   your Mac and click "Check for updates" in Settings > Updates. The update should download, and
   after the restart the native app should open in its place and import your data. The other Macs
   check 10 seconds after Bifrost starts and then every hour, and they install a downloaded update
   only when Bifrost quits or restarts, so there's a little time to react.

If the update fails on your Mac, Electron Bifrost keeps running and keeps its data. Turn the
release back into a draft straight away, so the other Macs don't get it:

```sh
gh release edit v1.0.0 -R Keane54/bifrost --draft=true
```

With the release a draft, the newest published release is v0.9.0 again, so the Electron copies see
no update. On your own Mac, the fix is a manual install of the DMG. The other Macs wait for a fixed
bridge, which is the next release: the tag `v1.0.0` stays, so a fix gives 1.0.1.

## One-time steps

### Secrets

The sign job reads these secrets from the `release` environment of the Bifrost repo:

| Secret | Value |
| --- | --- |
| `CSC_LINK` | The Developer ID Application certificate and its private key, as a `.p12` file in base64. |
| `CSC_KEY_PASSWORD` | The password of the `.p12` file. |
| `APPLE_API_KEY_P8` | The text of the App Store Connect API key (`.p8`), for notarisation. |
| `APPLE_API_KEY_ID` | The key ID of that API key. |
| `APPLE_API_ISSUER` | The issuer ID of that API key. |
| `SPARKLE_PRIVATE_KEY` | The private key of the Sparkle key pair. |

The first five already exist from the Electron releases and don't change. The workflow reads the
signing identity and the team ID from the certificate itself (`signing-identity.sh`), so no secret
holds a signing name.

Keep these secrets in the `release` environment and nowhere else. Environment secrets only reach a
job that names the environment, which is what keeps them away from the build job, and a copy as a
repository or organisation secret would undo that.

### The Sparkle key pair

The key pair exists: you made it on 2026-11-18. Its private key lives in your login Keychain and in
your backup, and its public key is in `Config/Release.xcconfig` as `SPARKLE_PUBLIC_KEY`. Keep the
pair for good: once a native release is out, the installed apps only accept updates signed with the
private key that matches the public key they were built with.

An xcconfig file treats `//` as the start of a comment, so a key containing `//` would be cut short
without any error. If you ever paste in a new key, write each `//` as `/$()/`.
`scripts/release/check-sparkle.sh` compares the key in the built app with the full line of the file,
and CI and every release run it.

What's left is to put the private key into its secret. Run these on the Mac whose Keychain holds the
key, from the repo after a package resolve (a `check.sh` run does one):

```sh
tools=.build/spm/artifacts/sparkle/Sparkle/bin
"$tools/generate_keys" -p
"$tools/generate_keys" -x ~/sparkle-private-key.txt
gh secret set SPARKLE_PRIVATE_KEY --env release -R Keane54/bifrost < ~/sparkle-private-key.txt
rm ~/sparkle-private-key.txt
```

The first command prints the public key, which must be the value of `SPARKLE_PUBLIC_KEY`. The
second exports the private key to a file outside the repo, the third stores it in the `release`
environment next to the other signing secrets, and the last deletes the file.

### The pinned Xcode

Both workflows pin Xcode 26.6 with `DEVELOPER_DIR`. If the `macos-26` runner image doesn't have
that version, the step "Check the Xcode version" fails and lists the versions it does have. Change
`DEVELOPER_DIR` in `ci.yml` and in both macOS jobs of `release.yml` together.

## Testing the release scripts

Two tests cover everything that doesn't need a secret:

- `scripts/test-release.sh` is a step of `check.sh`. It tests the summary rules, the reading of
  the signing identity, `latest-mac.yml` against a fixture ZIP, the appcast item, the check of the
  release files before publishing, the Sparkle settings (with the real resolved values of
  `Config/Release.xcconfig`), the Sparkle signature with a new test key, the checks of the Sparkle
  pin, the bridge check with ad hoc signed test apps, the signing order with a copy of
  Sparkle.framework, and the checks `prepare.sh` runs before it signs anything. It never reads the
  Keychain, builds no Release app and uses no network.
- `scripts/test-release-config.sh` runs semantic-release with a copy of `.releaserc.json` in
  temporary repos, with no network. Besides the version rules, it checks that a dry run saves the
  full notes, that a run with the files of the right version pushes the tag, and that files of
  another version stop it first. It needs `pnpm install --frozen-lockfile` first, and CI runs it on
  every push.

Never run `build-app.sh` on a Mac: it builds the Release app, which has the Electron app's bundle
ID. `prepare.sh` needs the signing secrets, so only the sign job runs it.

## What the cutover commit changes

The cutover commit replaces the Electron code in the Bifrost repo with this repo. On the release
side, it has to:

- use the message form above (`feat!:` with a `BREAKING CHANGE:` footer), so the first native
  release is 1.0.0;
- replace the Electron release files with these: `ci.yml` and `release.yml` take over,
  `pr-title.yml` stays the same, and `electron-builder.yml`, `electron-builder.release.ts`,
  `RELEASING.md` (this page replaces it), `scripts/verify-release.ts`, the TypeScript scripts in
  `scripts/release/`, and the Electron `package.json`, `pnpm-lock.yaml` and `pnpm-workspace.yaml`
  go, with the small `package.json` and lockfile of this repo in their place;
- give the README an Install section with the DMG link
  (`https://github.com/Keane54/bifrost/releases/latest/download/Bifrost-arm64.dmg`), and update the
  parts that say the repo is local only and has no CI;
- update the header of `scripts/check.sh`, which says it stands in for CI until cutover. Its
  `refuse-release` step stays as it is: CI runs `check.sh`, whose Release build never sets
  `BIFROST_CUTOVER`, so the smoke script must still refuse that app. Only the release workflow adds
  the condition;
- update the comments that say "before cutover" (in `StartGuard.swift`, `AppDelegate.swift`,
  `scripts/check_rules.py` and `Config/Release.xcconfig`), since the rule itself stays: no build
  configuration ever sets the condition;
- keep `BRIDGE_FROM_TAG` at the newest Electron release (v0.9.0 unless another one comes first).

Before the first native release, the secret `SPARKLE_PRIVATE_KEY` must be set, the first CI run on
`macos-26` must pass (it also proves the Xcode pin and the sandboxed tests on the runner), and a
dry run should pass.
