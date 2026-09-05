// SPDX-License-Identifier: MIT
import Foundation
import AppCore

/// G48-3: `.epub` の行で `content.pageCount` が「テキスト（画像本ではない）」を意味する
/// `BookContentError.unsupported(.text)` を投げたときだけ、manifest を EPUB 形式にフォールバックする。
/// 他のエラー（範囲外・描画失敗・開けない）は従来どおり呼び出し側で throw させる。
enum EPUBManifestFallback {
    static func isTextEPUB(path: String?, error: any Error) -> Bool {
        guard let path, (path as NSString).pathExtension.lowercased() == "epub" else { return false }
        guard let e = error as? BookContentError, case .unsupported(let category) = e, category == .text else { return false }
        return true
    }
}
