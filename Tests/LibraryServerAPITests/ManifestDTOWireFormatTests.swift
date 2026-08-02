// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

/// `ManifestDTO` は既存クライアントが読む wire 形式。`damageNote` は **nil ならキーごと省略**
/// されなければならない（`pageOverrides` と同じ後方互換方針）。旧クライアントは未知のキーを
/// 無視するだけなので、キーが「出ない」ことが後方互換の条件になる。
struct ManifestDTOWireFormatTests {
    static func json(_ dto: ManifestDTO) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(dto), as: UTF8.self)
    }

    @Test func omitsDamageNoteWhenNil() throws {
        let dto = ManifestDTO(pageCount: 12, direction: "rtl", format: "archive", etag: "\"e\"")
        let s = try Self.json(dto)
        #expect(s.contains("damageNote") == false)
        #expect(s == #"{"direction":"rtl","etag":"\"e\"","format":"archive","pageCount":12}"#)
    }

    @Test func emitsDamageNoteWhenPresent() throws {
        let dto = ManifestDTO(pageCount: 12, direction: "rtl", format: "archive", etag: "\"e\"",
                              damageNote: "⚠ 壊れています")
        let s = try Self.json(dto)
        #expect(s.contains(#""damageNote":"⚠ 壊れています""#))
    }
}
