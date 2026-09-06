// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackroomFormat

@Suite("G49: Path 欠落の復元規則")
struct StackroomPathRecoveryTests {
    @Test("Path があればそのまま")
    func keepsDeclaredPath() {
        #expect(StackroomPathRecovery.plan(path: "/b/x.zip", coverImagePath: "/c/y.zip") == .keep)
    }

    @Test("表紙パスが本そのもの（アーカイブ・PDF・EPUB）ならそれを使う")
    func usesCoverPathWhenItIsABook() {
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/x.zip") == .useCoverPath("/b/x.zip"))
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/x.CBZ") == .useCoverPath("/b/x.CBZ"))
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/x.rar") == .useCoverPath("/b/x.rar"))
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/x.7z") == .useCoverPath("/b/x.7z"))
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/x.pdf") == .useCoverPath("/b/x.pdf"))
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/x.epub") == .useCoverPath("/b/x.epub"))
    }

    @Test("表紙パスが画像ならその親ディレクトリが候補")
    func usesParentDirectoryWhenCoverIsAnImage() {
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/book/001.jpg")
                == .useCoverParentDirectory("/b/book"))
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/book/cover.PNG")
                == .useCoverParentDirectory("/b/book"))
    }

    @Test("空・拡張子なし・親が無いものは復元しない")
    func unrecoverable() {
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "") == .unrecoverable)
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "/b/noext") == .unrecoverable)
        #expect(StackroomPathRecovery.plan(path: nil, coverImagePath: "x.jpg") == .unrecoverable)
    }

    @Test("空文字の Path は宣言なしとして扱う")
    func emptyDeclaredPathIsTreatedAsMissing() {
        #expect(StackroomPathRecovery.plan(path: "", coverImagePath: "/b/x.zip") == .useCoverPath("/b/x.zip"))
    }
}
