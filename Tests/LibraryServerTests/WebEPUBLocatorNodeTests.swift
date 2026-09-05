import Testing
import Foundation

/// G48-3: Web の純粋関数（epub-locator.js）を node --test で走らせる。node が無い環境では skip（理由を出す）。
@Suite("Web: epub-locator.js（node --test）")
struct WebEPUBLocatorNodeTests {
    @Test func nodeTestsPass() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let testFile = repoRoot.appendingPathComponent("Tests/WebTests/epub-locator.test.mjs")
        let which = Process(); which.executableURL = URL(fileURLWithPath: "/usr/bin/env"); which.arguments = ["which", "node"]
        let whichOut = Pipe(); which.standardOutput = whichOut; which.standardError = Pipe()
        try which.run(); which.waitUntilExit()
        guard which.terminationStatus == 0 else {
            print("node が見つからないので skip（Web の純粋関数テストは未実行）"); return
        }
        let node = String(decoding: whichOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Process(); p.executableURL = URL(fileURLWithPath: node); p.arguments = ["--test", testFile.path]
        p.currentDirectoryURL = repoRoot
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run(); p.waitUntilExit()
        let log = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "node --test failed:\n\(log)\nrepoRoot=\(repoRoot.path) testFile=\(testFile.path)")
    }
}
