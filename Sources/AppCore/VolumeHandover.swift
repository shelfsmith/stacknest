// SPDX-License-Identifier: MIT
import Foundation

/// G54-S3e: 巻送りの引き渡しの事前確認と文言（spec §2.1・平木氏の判断 2026-09-25）。
///
/// 開けなかった `.epub` は `SiblingVolumeKind.probeLocal` がテキスト EPUB と見なすので、ファイルが無いと
/// 画像ビューアは**窓を閉じてから**所有者に開かせ、そこで初めて「見つかりません」になっていた。
/// 判定の前にファイルの有無を確かめ、**無いときだけ**窓に留まる。読む権限が無い（TCC）ときは今のまま
/// 引き渡す — 許可のダイアログは所有者の通常の経路（親フォルダを選ばせる導線）にしか無いため。
public enum VolumeHandover {
    /// 画像ビューアの巻送り（ローカル・オフライン）の事前確認。
    public enum ImageViewerPrecheck: Equatable, Sendable {
        /// 今までどおり判定へ進む。
        case proceed
        /// 窓に留まり、この文言を出す。
        case unavailable(note: String)
    }

    public static func imageViewerPrecheck(_ probe: FileReadProbe, forward: Bool) -> ImageViewerPrecheck {
        probe == .notFound ? .unavailable(note: missingFileNote(forward: forward)) : .proceed
    }

    /// EPUB の窓の巻送り（ローカル）の事前確認。
    public enum EPUBWindowPrecheck: Equatable, Sendable {
        /// ファイルが無い。開き直しても「見つかりません」になるだけで窓を失うので、今の本のまま（`.failed`）。
        case stay
        /// 読めない（TCC 等）。開き直して通常の経路の許可の導線へ（`.reopen`）。
        case reopen
        /// 読める。テキスト EPUB かどうかの判定へ進む。
        case probeKind
    }

    public static func epubWindowPrecheck(_ probe: FileReadProbe) -> EPUBWindowPrecheck {
        switch probe {
        case .notFound: return .stay
        case .noPermission: return .reopen
        case .readable: return .probeKind
        }
    }

    /// 「次（前）の巻を開けません（ファイルが見つかりません）」。
    public static func missingFileNote(forward: Bool) -> String {
        "\(unavailableNote(forward: forward))（ファイルが見つかりません）"
    }

    /// 「次（前）の巻を開けません」（EPUB の窓の `.failed` と同じ言い方）。
    public static func unavailableNote(forward: Bool) -> String {
        forward ? "次の巻を開けません" : "前の巻を開けません"
    }
}
