// SPDX-License-Identifier: MIT
import Testing
import Foundation

/// G48: `import WashiCore` が `Sources/WashiEPUBAdapter/` の外に無いことを固定する。
/// Washi は差し替え前提（平木氏の指示）。AppCore 等から直接呼ぶと差し替えが 1 ターゲットの入れ替えで済まなくなる。
@Suite("Washi の境界")
struct ImportBoundaryTests {
    @Test("import WashiCore は Sources/WashiEPUBAdapter/ の中にしか無い")
    func washiImportIsConfined() throws {
        // Tests/EPUBAdapterTests/ImportBoundaryTests.swift → リポジトリ root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let fm = FileManager.default
        guard let e = fm.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("Sources/ が見つからない: \(sources.path)"); return
        }
        var offenders: [String] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("import WashiCore") else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if !rel.hasPrefix("Sources/WashiEPUBAdapter/") { offenders.append(rel) }
        }
        #expect(offenders.isEmpty, "WashiCore を直接 import している: \(offenders)")
    }
}
