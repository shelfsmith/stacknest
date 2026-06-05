// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CryptoKit
@testable import AppCore

@Suite("ContentHasher — streaming SHA-256 of a file")
struct ContentHasherTests {
    @Test func matchesCryptoKitOneShot() throws {
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hash_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("blob.bin")
        try bytes.write(to: url)

        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let actual = try ContentHasher.sha256(ofFileAt: url)
        #expect(actual == expected)
    }

    @Test func throwsForMissingFile() {
        let url = URL(fileURLWithPath: "/no/such/file/\(UUID().uuidString)")
        #expect(throws: (any Error).self) { _ = try ContentHasher.sha256(ofFileAt: url) }
    }
}
