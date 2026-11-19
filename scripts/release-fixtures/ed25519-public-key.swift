// Prints the public key of an Ed25519 private key as base64, for scripts/test-release.sh.
//
// Usage: swift scripts/release-fixtures/ed25519-public-key.swift <private key as base64>
//
// The private key is the 32-byte seed, the form that "generate_keys -x" of Sparkle exports. The
// test makes a new key for each run, so no key is in the repo.
import CryptoKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1, let seed = Data(base64Encoded: arguments[0]),
    let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    FileHandle.standardError.write(Data("usage: ed25519-public-key.swift <private key>\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
