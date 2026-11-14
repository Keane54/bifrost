// The build of the Release workflow (RELEASING.md). It is electron-builder.yml plus the
// Developer ID signature, the hardened runtime and the notarisation. Local builds use
// electron-builder.yml, so they need no certificate.
//
// The workflow gives these environment variables:
// - APPLE_SIGNING_IDENTITY: the name of the certificate, with no "Developer ID Application:". The
//   workflow reads it from the certificate in CSC_LINK (scripts/release/signing-identity.ts).
// - CSC_KEYCHAIN: the path of a keychain that holds the certificate. The workflow makes this
//   keychain from the CSC_LINK and CSC_KEY_PASSWORD secrets.
// - APPLE_API_KEY (the path of the .p8 file), APPLE_API_KEY_ID and APPLE_API_ISSUER: the App Store
//   Connect key for notarytool. electron-builder staples the ticket to the app.
import type { Configuration } from 'electron-builder'

const PREFIX = 'Developer ID Application:'
const ENTITLEMENTS = 'build/entitlements.mac.plist'

export function releaseConfig(
  env: Record<string, string | undefined> = process.env,
): Configuration {
  const identity = env.APPLE_SIGNING_IDENTITY?.trim() ?? ''
  if (identity === '') {
    throw new Error(
      'APPLE_SIGNING_IDENTITY is not set. A release needs the name of a Developer ID ' +
        'Application certificate, for example "Jane Doe (ABCDE12345)". See RELEASING.md.',
    )
  }
  if (identity.startsWith(PREFIX)) {
    throw new Error(
      `Remove "${PREFIX}" from APPLE_SIGNING_IDENTITY. electron-builder adds it. See RELEASING.md.`,
    )
  }
  return {
    extends: './electron-builder.yml',
    // The entitlements file has the audio-input entitlement. The hardened runtime blocks the
    // microphone without it. The helpers keep the default inherit file of electron-builder. They
    // need no microphone, because macOS gives it to the main app. This is also true for the speech
    // helper of dictation (mac.binaries in electron-builder.yml): macOS checks the microphone
    // permission of Bifrost, the app that starts the helper.
    mac: {
      entitlements: ENTITLEMENTS,
      hardenedRuntime: true,
      identity,
      notarize: true,
    },
    // electron-builder writes latest-mac.yml and app-update.yml from this block. The dist:release
    // script passes --publish never, so electron-builder uploads nothing. semantic-release
    // uploads the files. Local builds have no publish block. So they have no app-update.yml, and
    // the updater does not start.
    publish: { owner: 'Keane54', provider: 'github', releaseType: 'release', repo: 'bifrost' },
  }
}

export default () => releaseConfig()
