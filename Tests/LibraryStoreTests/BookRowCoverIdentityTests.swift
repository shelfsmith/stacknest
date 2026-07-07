// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// G4b smoke で判明した「外部表紙の再アップロード時に詳細ペインの表紙が
/// 再描画されない」stale バグの回帰ガード。
///
/// 詳細ペイン CoverImageView は再描画/再取得の identity を表紙メタ
/// （coverImageName / coverCropRect）だけに紐付けていたため、外部画像を
/// 差し替えても coverImageName="@external" が不変だと identity が変わらず、
/// キャッシュ無効化後も @State image を再利用してしまった。cover 書き込み
/// ごとに増える coverVersion を identity に含めることで解消する。
@Suite("BookRow cover render/fetch identity (G4b stale fix)")
struct BookRowCoverIdentityTests {
    private func makeBook(coverImageName: String?, crop: CGRect?) -> BookRow {
        BookRow(
            id: 42, title: "Sample", author: nil, genre: nil,
            path: nil, dateAdded: Date(timeIntervalSince1970: 0), playDate: nil,
            bookType: 0, fileType: 2, pages: nil, rating: 0, unseen: false,
            keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil,
            coverImageName: coverImageName, coverCropRect: crop)
    }

    @Test("外部再アップロード: メタ不変でも coverVersion 増加で render identity が変化")
    func renderIdentityChangesWithVersion() {
        let book = makeBook(coverImageName: "@external", crop: nil)
        #expect(book.coverRenderIdentity(coverVersion: 1) != book.coverRenderIdentity(coverVersion: 2))
    }

    @Test("外部再アップロード: メタ不変でも coverVersion 増加で fetch identity が変化（再取得トリガ）")
    func fetchIdentityChangesWithVersion() {
        let book = makeBook(coverImageName: "@external", crop: nil)
        #expect(book.coverFetchIdentity(coverVersion: 1) != book.coverFetchIdentity(coverVersion: 2))
    }

    @Test("coverImageName の違いは従来どおり両 identity に反映される")
    func identityReflectsCoverName() {
        let a = makeBook(coverImageName: nil, crop: nil)
        let b = makeBook(coverImageName: "@external", crop: nil)
        #expect(a.coverRenderIdentity(coverVersion: 0) != b.coverRenderIdentity(coverVersion: 0))
        #expect(a.coverFetchIdentity(coverVersion: 0) != b.coverFetchIdentity(coverVersion: 0))
    }

    @Test("crop 変化は render のみに影響し fetch identity は不変（切り抜きは再描画のみで再取得不要）")
    func cropAffectsRenderNotFetch() {
        let a = makeBook(coverImageName: "@external", crop: nil)
        let b = makeBook(coverImageName: "@external", crop: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        #expect(a.coverRenderIdentity(coverVersion: 0) != b.coverRenderIdentity(coverVersion: 0))
        #expect(a.coverFetchIdentity(coverVersion: 0) == b.coverFetchIdentity(coverVersion: 0))
    }
}
