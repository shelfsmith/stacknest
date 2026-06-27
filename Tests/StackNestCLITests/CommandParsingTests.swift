// SPDX-License-Identifier: MIT
import Testing
import ArgumentParser
@testable import StackNestCLI

@Suite("サブコマンドのパース健全性（--help が ArgumentParser 検証を通る）")
struct CommandParsingTests {
    /// 全 leaf サブコマンドのパス（`--help` を付けて parseAsRoot に渡す）。
    static let commands: [[String]] = [
        ["libraries"], ["list"], ["add"], ["rm"], ["set"], ["detail"], ["facets"],
        ["shelves"], ["me"], ["unlock"], ["relink"], ["dedup"],
        ["shelf", "create"], ["shelf", "rm"], ["shelf", "rename"],
        ["shelf", "conditions-get"], ["shelf", "conditions-set"],
        ["shelf", "add-books"], ["shelf", "remove-books"],
        ["watch", "get"], ["watch", "set"],
        ["lock", "set"], ["lock", "clear"],
        ["import-config", "get"], ["import-config", "set"],
        ["import-config-global", "get"], ["import-config-global", "set"],
        ["grant", "list"], ["grant", "create"], ["grant", "update"], ["grant", "rm"],
        ["stamp"], ["stamp-definitions", "get"], ["stamp-definitions", "set"],
        ["label", "get"], ["label", "set"],
    ]

    @Test(arguments: commands)
    func helpParsesWithoutValidationError(_ path: [String]) {
        do {
            _ = try Stacknest.parseAsRoot(path + ["--help"])
            // --help は通常 throw する（CleanExit）。例外なく返る場合も成功扱い。
        } catch {
            let code = Stacknest.exitCode(for: error)
            #expect(code == .success,
                    "サブコマンド \(path.joined(separator: " ")) のパースに失敗: \(Stacknest.fullMessage(for: error))")
        }
    }
}
