// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

@Suite("OpenMode safety contract")
struct OpenModeTests {
    @Test("createOrFail throws when file exists")
    func createOrFailThrowsOnExisting() throws {
        let url = URL(fileURLWithPath: "/tmp/openmode-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let db1 = try Database.openFile(at: url, mode: .createOrFail)
        db1.close()

        #expect(throws: ImportError.dbExistsWithoutForce(url)) {
            _ = try Database.openFile(at: url, mode: .createOrFail)
        }
    }

    @Test("createOrReplace deletes existing file and creates fresh")
    func createOrReplaceWipes() throws {
        let url = URL(fileURLWithPath: "/tmp/openmode-replace-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let db1 = try Database.openFile(at: url, mode: .createOrFail)
        try db1.migrate()
        db1.close()
        let exists1 = FileManager.default.fileExists(atPath: url.path)
        #expect(exists1)

        let db2 = try Database.openFile(at: url, mode: .createOrReplace)
        db2.close()
        let exists2 = FileManager.default.fileExists(atPath: url.path)
        #expect(exists2)  // file recreated
    }

    @Test("createOrFail succeeds when file does not exist")
    func createOrFailNewFile() throws {
        let url = URL(fileURLWithPath: "/tmp/openmode-new-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try Database.openFile(at: url, mode: .createOrFail)
        #expect(db.isOpen)
        db.close()
    }

    @Test("openExisting opens an existing DB")
    func openExistingOpensExistingDB() throws {
        let url = URL(fileURLWithPath: "/tmp/openexisting-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let setup = try Database.openFile(at: url, mode: .createOrFail)
        try setup.migrate()
        setup.close()

        let db = try Database.openExisting(at: url)
        #expect(db.isOpen)
        let cols = try db.fetchImportMetaColumnNames()
        #expect(cols.contains("schema_version"))
        db.close()
    }

    @Test("openExisting throws when file does not exist")
    func openExistingThrowsWhenMissing() throws {
        let url = URL(fileURLWithPath: "/tmp/openexisting-missing-\(UUID().uuidString).sqlite")
        // file does NOT exist
        #expect(throws: ImportError.dbNotFound(url)) {
            _ = try Database.openExisting(at: url)
        }
    }
}
