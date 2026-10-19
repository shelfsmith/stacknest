// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation

/// 外部ビューアに見せる本の同一性（manifest の `bookIdentity`）。
///
/// 外部ビューアは参照ファイルの `book`（ポート・中継の id が渡すたびに変わる）や題名から本を見分けられないので、
/// ブックマークやページのレイアウトを本ごとに残せない。そこで、同じライブラリの同じ本なら改題・ファイルの移動
/// （付け直し）・StackNest の再起動・中継を通しても変わらない値を manifest に載せる。
///
/// 値は書庫の UUID・本の番号・本の印（`ViewerTokenRecord.bookStamp`＝取り込み日時）から作る SHA-256 で、
/// ビューアには中身を読ませない（書庫や本の番号を値から取り出せない・作り方を後で変えられる）。本の印を混ぜるのは、
/// 本の番号が使い回されうるため（消した本の番号が次に取り込んだ本に付く）。鍵の照合と同じ考え方で、使い回された
/// 番号の本は別の値になる。形は StackNestViewerKit の約束（ASCII の英数字と `-._~:`・128 文字まで）に収まる
/// `sn1-` ＋ base64url（47 文字）。
public enum ViewerBookIdentity {
    /// 値の頭（作り方の版）。作り方を変えるときは別の頭にする（同じ本が別の値になるのは避けられないが、混ざらない）。
    public static let prefix = "sn1-"

    public static func value(libraryUUID: String, bookID: Int, dateAdded: Date) -> String {
        let material = [
            "stacknest.viewer-book-identity.v1",
            libraryUUID.lowercased(),
            String(bookID),
            ViewerTokenRecord.bookStamp(dateAdded: dateAdded),
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        let base64 = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + base64
    }
}
