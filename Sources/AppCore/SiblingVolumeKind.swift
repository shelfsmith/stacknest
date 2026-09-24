// SPDX-License-Identifier: MIT
import Foundation
import EPUBAdapter

/// G54-S3c: 巻送りの次（前）の巻を、どのビューアで読むかで分ける。
/// テキスト EPUB は EPUB の窓（Washi）、それ以外（zip・フォルダ・PDF・画像本 EPUB）は画像ビューア。
/// EPUB の窓（同じ窓で差し替えるか／開き直すか）と画像ビューア（差し替えるか／EPUB の窓へ渡すか）の両方が使う。
public enum SiblingVolumeKind: Equatable, Sendable {
    case textEPUB
    case other

    /// ローカル・オフラインのファイル。`isImageBook` は `openImageBook` の結果
    /// （true = 画像本 / false = 画像本でない / nil = 確かめられなかった）。
    /// 確かめられなかった .epub はテキスト EPUB として扱う（本を開く経路 `openInBuiltInViewer` が
    /// 判定に失敗したとき EPUB の窓へ落とすのと同じ）。
    public static func local(path: String?, isImageBook: Bool?) -> SiblingVolumeKind {
        guard isEPUB(path) else { return .other }
        return isImageBook == true ? .other : .textEPUB
    }

    /// リモート。判定の正はサーバの manifest（`RemoteEPUBRouting` と同じ規則）。
    /// manifest が取れなかったときは `.other`（開き直す経路が失敗の表示まで面倒を見る）。
    public static func remote(filename: String?, manifestFormat: String?) -> SiblingVolumeKind {
        guard let manifestFormat else { return .other }
        return RemoteEPUBRouting.route(filename: filename, manifestFormat: manifestFormat) == .textEPUB
            ? .textEPUB : .other
    }

    /// ローカル・オフラインのファイルを確かめる。.epub のときだけ `openImageBook` を呼ぶ。
    /// 画像本なら開いた handle も返す（画像ビューアの巻送りで同じ本を 2 回開かないため）。
    public static func probeLocal(path: String?, reader: (any EPUBReading)?)
        async -> (kind: SiblingVolumeKind, imageBook: (any EPUBImageBookReading)?) {
        guard let path, isEPUB(path) else { return (.other, nil) }
        guard let reader else { return (local(path: path, isImageBook: nil), nil) }
        do {
            let handle = try await reader.openImageBook(url: URL(fileURLWithPath: path))
            return (local(path: path, isImageBook: handle != nil), handle)
        } catch {
            return (local(path: path, isImageBook: nil), nil)
        }
    }

    private static func isEPUB(_ path: String?) -> Bool {
        guard let path else { return false }
        return (path as NSString).pathExtension.lowercased() == "epub"
    }
}
