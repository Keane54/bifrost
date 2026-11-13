# Releasing Bifrost

A release is a signed and notarised DMG, with the update files. The Release workflow builds it on a
GitHub macOS runner. A person starts the workflow manually.

## What a release needs

- A Developer ID Application certificate. Only the Account Holder of the Apple Developer team can
  make it.
- An App Store Connect API key, for notarisation.
- A GitHub environment named `release`. Set it to allow only the `main` branch.

## Make the certificate and the key

1. Make a certificate signing request in Keychain Access.
2. The Account Holder opens the Apple Developer site. The Account Holder makes a Developer ID
   Application certificate from the request.
3. Install the certificate in Keychain Access.
4. Export the certificate and its private key as a `.p12` file. Set a password.
5. Open App Store Connect. Make an API key. Download the `.p8` file one time. Note the key ID
   and the issuer ID.

## Set the secrets

Set five secrets in the `release` environment. Use this command for each one:

```sh
gh secret set <NAME> --env release -R <owner>/<repo>
```

| Secret | Value |
|---|---|
| `CSC_LINK` | The `.p12` file as base64 (command below). |
| `CSC_KEY_PASSWORD` | The password of the `.p12` file. |
| `APPLE_API_KEY_P8` | The text of the `.p8` file. |
| `APPLE_API_KEY_ID` | The key ID of the API key. |
| `APPLE_API_ISSUER` | The issuer ID of the API key. |

The workflow reads the signing name and the team ID from the certificate in `CSC_LINK`. Both are
public, because each released app shows them in its code signature. You set no secret for them.
The `.p12` file must hold exactly one Developer ID Application certificate with its private key.
The name of the certificate must end with the team ID in brackets. Example:
`Developer ID Application: Example Corp Ltd (ABCDE12345)`.

Encode the `.p12` file and set `CSC_LINK` in one command:

```sh
base64 -i cert.p12 | gh secret set CSC_LINK --env release -R <owner>/<repo>
```

The workflow stops at "Read the signing identity" when the keychain holds no Developer ID
Application identity, when it holds more than one, or when the name does not end with a team ID in
brackets.

## Start a release

1. Start a `dry-run` first. It builds, signs and notarises the files. It makes no tag and no
   release.
2. Download the files of the dry run. Check them.
3. Start a `release`.

Open Actions, then Release, then Run workflow. Or use this command:

```sh
gh workflow run release.yml -R <owner>/<repo> -f mode=dry-run -f summary="<text>"
```

For a release, use `-f mode=release`.

## Change the team or the certificate

Installed copies cannot update to a build from another team or another certificate by
themselves. Each Mac needs one manual install of the new DMG.

## Make a fork

Change the owner and the repo in these files:

- `src/main/updates/updater.ts`
- `scripts/verify-release.ts`
- `electron-builder.release.ts`

A unit test checks that the three files agree.

## Local builds

`pnpm dist` signs the app ad hoc. It needs no certificate.
Do not run `pnpm dist:release` on your Mac.
It needs the secrets and a keychain with the certificate.
