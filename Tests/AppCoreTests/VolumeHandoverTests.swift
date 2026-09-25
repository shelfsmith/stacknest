// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G54-S3e（spec §2.1-2〜4・平木氏の判断）: 次の巻のファイルが**無いときだけ**窓に留まる。
/// 読む権限が無い（TCC）ときは今のまま引き渡す（許可のダイアログを出さないと直せないため）。
@Suite("G54-S3e: 巻送りの引き渡しの事前確認")
struct VolumeHandoverTests {
    @Test func imageViewerStaysOnlyWhenTheFileIsMissing() {
        #expect(VolumeHandover.imageViewerPrecheck(.notFound, forward: true)
                == .unavailable(note: "次の巻を開けません（ファイルが見つかりません）"))
        #expect(VolumeHandover.imageViewerPrecheck(.noPermission, forward: true) == .proceed)
        #expect(VolumeHandover.imageViewerPrecheck(.readable, forward: true) == .proceed)
    }

    /// Review Focus 4: 前の巻へ戻る方向では「前の巻を…」。
    @Test func previousVolumeSaysPrevious() {
        #expect(VolumeHandover.imageViewerPrecheck(.notFound, forward: false)
                == .unavailable(note: "前の巻を開けません（ファイルが見つかりません）"))
        #expect(VolumeHandover.unavailableNote(forward: true) == "次の巻を開けません")
        #expect(VolumeHandover.unavailableNote(forward: false) == "前の巻を開けません")
    }

    /// EPUB の窓: 無ければ留まる（`.failed`）、読めなければ開き直して許可の導線へ（`.reopen`）、読めれば判定へ。
    @Test func epubWindowStaysOnlyWhenTheFileIsMissing() {
        #expect(VolumeHandover.epubWindowPrecheck(.notFound) == .stay)
        #expect(VolumeHandover.epubWindowPrecheck(.noPermission) == .reopen)
        #expect(VolumeHandover.epubWindowPrecheck(.readable) == .probeKind)
    }
}
