// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackroomFormat

@Suite("G49: Path 欠落の復元規則")
struct StackroomPathRecoveryTests {
    /// Stackroom の `File Type`。2 = zip（実書庫のほぼすべて）、4 = フォルダ書籍。
    private let archive = 2
    private let folder = 4

    @Test("Path があればそのまま")
    func keepsDeclaredPath() {
        #expect(StackroomPathRecovery.plan(
            path: "/b/x.zip", coverImagePath: "/c/y.zip", fileType: archive) == .keep)
    }

    @Test("表紙パスが本そのもの（アーカイブ・PDF・EPUB）ならそれを使う")
    func usesCoverPathWhenItIsABook() {
        for name in ["/b/x.zip", "/b/x.CBZ", "/b/x.rar", "/b/x.7z", "/b/x.pdf", "/b/x.epub"] {
            #expect(StackroomPathRecovery.plan(
                path: nil, coverImagePath: name, fileType: archive) == .useCoverPath(name))
        }
    }

    @Test("フォルダ書籍で表紙が画像なら、その親ディレクトリが候補")
    func usesParentDirectoryWhenCoverIsAnImage() {
        #expect(StackroomPathRecovery.plan(
            path: nil, coverImagePath: "/b/book/001.jpg", fileType: folder)
                == .useCoverParentDirectory("/b/book"))
        #expect(StackroomPathRecovery.plan(
            path: nil, coverImagePath: "/b/book/cover.PNG", fileType: folder)
                == .useCoverParentDirectory("/b/book"))
    }

    /// 実書庫に、zip の本の表紙が別フォルダの画像を指している例がある。
    /// そこを本の場所と推定すると、開く・表示する・改名がすべて誤った先を向く。
    @Test("アーカイブと分かっている本では、画像の親ディレクトリを本の場所にしない")
    func doesNotUseParentDirectoryForArchiveBooks() {
        #expect(StackroomPathRecovery.plan(
            path: nil, coverImagePath: "/b/book/001.jpg", fileType: archive) == .unrecoverable)
        // 意味の確定していない File Type もアーカイブ側に寄せる（誤った推定より復元しないほうが安全）
        #expect(StackroomPathRecovery.plan(
            path: nil, coverImagePath: "/b/book/001.jpg", fileType: 3) == .unrecoverable)
    }

    @Test("空・拡張子なし・親が無いものは復元しない")
    func unrecoverable() {
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "", fileType: archive) == .unrecoverable)
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/noext", fileType: archive) == .unrecoverable)
    }

    @Test("相対パスは本の場所として使えないので復元しない")
    func relativePathsAreRejected() {
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "x.zip", fileType: archive) == .unrecoverable)
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "x.jpg", fileType: folder) == .unrecoverable)
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "b/x.zip", fileType: archive) == .unrecoverable)
    }

    @Test("空文字の Path は宣言なしとして扱う")
    func emptyDeclaredPathIsTreatedAsMissing() {
        #expect(StackroomPathRecovery.plan(
            path: "", coverImagePath: "/b/x.zip", fileType: archive) == .useCoverPath("/b/x.zip"))
    }
}
