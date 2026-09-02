// SPDX-License-Identifier: MIT
import Foundation

/// G48: EPUB から StackNest が要るものだけを取り出す契約。
/// 実装（Washi 等）はこの裏に隔離し、差し替えは「新しい実装ターゲット → 登録 1 行 → 旧ターゲット削除」で閉じる。
/// **契約を太らせない**: 全文検索・目次・読書位置は別の契約にする（段階 2）。
public protocol EPUBReading: Sendable {
    /// メタデータを読む。開けなければ `EPUBAdapterError.cannotOpen`。
    func open(url: URL) async throws -> EPUBBookInfo
    /// 表紙を JPEG または PNG のバイト列で返す。表紙画像が無い本は nil（エラーではない）。
    func coverImageData(url: URL, maxPixelSize: Int) async throws -> Data?
}
