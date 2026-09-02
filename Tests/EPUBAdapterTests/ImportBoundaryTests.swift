// SPDX-License-Identifier: MIT
import Testing
import Foundation

/// G48: `import WashiCore` が `Sources/WashiEPUBAdapter/` の外に無いことを固定する。
/// Washi は差し替え前提（ユーザーの指示）。AppCore 等から直接呼ぶと差し替えが 1 ターゲットの入れ替えで済まなくなる。
@Suite("Washi の境界")
struct ImportBoundaryTests {
    @Test("import WashiCore / import Washi は Sources/WashiEPUBAdapter/ の中にしか無い")
    func washiImportIsConfined() throws {
        // Tests/EPUBAdapterTests/ImportBoundaryTests.swift → リポジトリ root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // G48-2 最終レビュー G: App/ も走査対象に足す。App/StackNestApp.swift は
        // `import WashiEPUBAdapter`（アダプタ経由）で問題ないが、そこから直接
        // `import Washi`/`import WashiCore` してしまう回帰も同じ規律で守る。
        let scanRoots = ["Sources", "App"].map { root.appendingPathComponent($0) }
        let fm = FileManager.default
        // App/build・.build 等はビルド生成物（.gitignore 済）で、稼働状況によって存在有無が
        // 変わり非決定的になる（vendored な checkout の中に本物の import Washi/WashiCore がある）。
        // ソースではないので走査から除外する。
        let excludedDirNames: Set<String> = ["build", ".build", "DerivedData", ".git"]
        // `import WashiEPUBAdapter` を誤検知しないよう行頭マッチ＋単語境界にする
        // （旧実装の `.contains("import Washi ")` 等の部分文字列判定はコメント中の
        // 「// import Washi」等も拾ってしまい得た）。
        let pattern = try NSRegularExpression(pattern: #"^\s*import\s+Washi(Core)?\b"#)
        var offenders: [String] = []
        for scanRoot in scanRoots {
            guard let e = fm.enumerator(at: scanRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
                Issue.record("ディレクトリが見つからない: \(scanRoot.path)"); continue
            }
            for case let url as URL in e {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if excludedDirNames.contains(url.lastPathComponent) { e.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let hasWashiImport = text.components(separatedBy: "\n").contains { line in
                    pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                }
                guard hasWashiImport else { continue }
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                if !rel.hasPrefix("Sources/WashiEPUBAdapter/") { offenders.append(rel) }
            }
        }
        #expect(offenders.isEmpty, "WashiCore/Washi を直接 import している: \(offenders)")
    }
}
