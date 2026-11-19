// Checks an EdDSA (Ed25519) signature of Sparkle with a public key.
//
// Usage: swift scripts/release/verify-ed-signature.swift <public key> <signature> <file>
//
// The public key and the signature are base64 text, as in SUPublicEDKey and in the
// sparkle:edSignature attribute of an appcast. Sparkle signs the bytes of the file, so the script
// checks the signature against all bytes of the file. sparkle-sign.sh runs this script.
//
// Exit 0: the signature is correct. Exit 1: the signature is not correct, or an argument is
// not correct.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
    fail("usage: swift verify-ed-signature.swift <public key> <signature> <file>")
}
guard let keyData = Data(base64Encoded: arguments[0]),
    let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else {
    fail("the public key is not the base64 text of a 32-byte Ed25519 key")
}
guard let signature = Data(base64Encoded: arguments[1]), signature.count == 64 else {
    fail("the signature is not the base64 text of a 64-byte Ed25519 signature")
}
guard let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: .alwaysMapped)
else {
    fail("cannot read \(arguments[2])")
}
guard publicKey.isValidSignature(signature, for: data) else {
    fail("the signature does not match the public key and the file")
}
print("The signature matches the public key.")
