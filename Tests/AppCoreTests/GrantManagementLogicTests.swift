// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
@testable import AppCore

@Suite("GrantManagementLogic")
struct GrantManagementLogicTests {
    private func g(_ id: String, _ scope: GrantScope = .all) -> Grant {
        Grant(id: id, label: id, token: "t-\(id)", tier: .read, scope: scope,
              createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func customGrantsExcludesOnlyEnvAdmin() {
        let all = [g("default-read"), g("default-edit"), g("env-admin"), g("user-1"), g("user-2")]
        // 一本化(C-③b-2): default-read/default-edit も「共有トークン」として一覧に含める。env-admin のみ除外。
        #expect(GrantManagementLogic.customGrants(all).map(\.id) == ["default-read", "default-edit", "user-1", "user-2"])
    }

    @Test func scopeSummaryText() {
        #expect(GrantManagementLogic.scopeSummary(.all) == "全ライブラリ")
        #expect(GrantManagementLogic.scopeSummary(.libraries(["a", "b"])) == "2 庫")
        #expect(GrantManagementLogic.scopeSummary(.libraries([])) == "0 庫")
    }

    @Test func validationRejectsEmptyLabel() {
        #expect(GrantManagementLogic.isValidInput(label: "", scopeIsAll: true, selectedLibraryCount: 0) == false)
        #expect(GrantManagementLogic.isValidInput(label: "   ", scopeIsAll: true, selectedLibraryCount: 0) == false)
    }

    @Test func validationScopeRules() {
        #expect(GrantManagementLogic.isValidInput(label: "家族", scopeIsAll: true, selectedLibraryCount: 0) == true)
        #expect(GrantManagementLogic.isValidInput(label: "家族", scopeIsAll: false, selectedLibraryCount: 0) == false)
        #expect(GrantManagementLogic.isValidInput(label: "家族", scopeIsAll: false, selectedLibraryCount: 1) == true)
    }
}
