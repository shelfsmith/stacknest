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
    /// `manifestFormat == nil` は `.other`。ただしリモートの EPUB の窓の巻送りは、manifest が取れなかったときに
    /// この関数へ来ない — `remoteDecision` が「取り込み済みならローカルの判定・未ダウンロードなら今の本のまま」に分ける。
    public static func remote(filename: String?, manifestFormat: String?) -> SiblingVolumeKind {
        guard let manifestFormat else { return .other }
        return RemoteEPUBRouting.route(filename: filename, manifestFormat: manifestFormat) == .textEPUB
            ? .textEPUB : .other
    }

    /// G54-S3c: リモートの EPUB の窓で、次（前）の巻をどう扱うか。
    public enum RemoteSiblingDecision: Equatable, Sendable {
        /// テキスト EPUB。同じ窓で差し替える。
        case swap
        /// テキスト EPUB 以外。窓を閉じて通常の経路で開き直す。
        case reopen
        /// 決められない（未ダウンロードで manifest が取れない）。今の本のまま。
        case failed
    }

    /// G54-S3c: リモートの次（前）の巻の扱いを決める。
    /// - `localKind`: 取り込み済み（ローカルのファイルがある）なら `probeLocal` の結果。未ダウンロードなら nil。
    ///   取り込み済みならファイルそのものが正（manifest より優先）。
    /// - `manifestFetched`: manifest を取れたか。未ダウンロードで取れなければ `.failed` ――
    ///   開き直しても `openViewer` が同じ manifest を要るので必ず失敗し、窓だけ失う（spec §4.1「今の本のまま」）。
    public static func remoteDecision(localKind: SiblingVolumeKind?, manifestFetched: Bool,
                                      filename: String?, manifestFormat: String?) -> RemoteSiblingDecision {
        let kind: SiblingVolumeKind
        if let localKind {
            kind = localKind
        } else if manifestFetched {
            kind = remote(filename: filename, manifestFormat: manifestFormat)
        } else {
            return .failed
        }
        return kind == .textEPUB ? .swap : .reopen
    }

    /// G54-S3e（spec §2.1-7）: リモートの EPUB の窓で、次（前）の巻の manifest を取る必要があるか。
    /// 取り込み済みでテキスト以外（`remoteDecision` が manifest に関係なく `.reopen` を返す）なら要らない —
    /// 開き直した先は手元のファイルで読むので、使わない manifest を取らない。
    public static func remoteNeedsManifest(localKind: SiblingVolumeKind?) -> Bool {
        localKind != .other
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
