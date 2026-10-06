import CryptoKit
import Foundation

// Generate disposable test keys without touching the user's Keychain.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let key = Curve25519.Signing.PrivateKey()
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try key.rawRepresentation.base64EncodedString().write(
    to: directory.appendingPathComponent("private-key"), atomically: true, encoding: .utf8)
try FileManager.default.setAttributes(
    [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("private-key").path)
try key.publicKey.rawRepresentation.base64EncodedString().write(
    to: directory.appendingPathComponent("public-key"), atomically: true, encoding: .utf8)
