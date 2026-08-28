// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryServerAPI
@testable import StackNest

/// エンドポイントの**組み立て**を確かめる。
/// 実際の HTTP や AppState は使わない（テストホストで NSWindow を作ると固まる）。
@Suite("rename-files の応答の組み立て")
struct RenameFilesControlTests {
    @Test("計画のみのときは applied=false・renamed=0")
    func planOnly() {
        let rows = [
            RenamePlanRow(id: 1, oldPath: "/x/a.zip", newPath: "/x/A.zip",
                          oldName: "a.zip", newName: "A.zip", status: .ok),
            RenamePlanRow(id: 2, oldPath: "/x/b.zip", newPath: "",
                          oldName: "b.zip", newName: "", status: .emptyName),
        ]
        let reply = RenameFilesReply(
            status: "ok", applied: false,
            rows: rows.map { RenamePlanRowDTO(id: $0.id, oldName: $0.oldName,
                                              newName: $0.newName, status: $0.status.rawValue) },
            missingIDs: [], renamed: 0, skipped: rows.filter { $0.status != .ok }.count)
        #expect(reply.applied == false)
        #expect(reply.renamed == 0)
        #expect(reply.skipped == 1)
        #expect(reply.rows[1].status == "emptyName")
    }

    @Test("居ない ID は rows ではなく missingIDs に入る")
    func missingSeparate() {
        let reply = RenameFilesReply(status: "ok", applied: false, rows: [],
                                     missingIDs: [42], renamed: 0, skipped: 0)
        #expect(reply.missingIDs == [42])
        #expect(reply.rows.isEmpty)
    }

    @Test("施錠中は rows が空")
    func locked() {
        let reply = RenameFilesReply(status: "locked")
        #expect(reply.status == "locked")
        #expect(reply.applied == false)
        #expect(reply.rows.isEmpty)
    }
}
