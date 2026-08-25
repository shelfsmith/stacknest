// SPDX-License-Identifier: MIT
import Foundation
import AppCore

/// 監視フォルダの自動取り込みの結果を、上端バナーの文言に落とす。
///
/// `FinderTagSyncNotice.make(outcome:trigger:fieldLabel:)` と同じ作法 ——
/// **DB も UI も触らない純粋関数**にして、文言と種別の判断をテストで固定できるようにする。
///
/// ★ **これまで `ImportResult` の情報を捨てていた。**「N 件失敗」としか言わず、
/// `failed` が持っている URL とエラーも、`cancelled` の印も届いていなかった。
enum WatchImportNotice {
    /// 詳細に並べる最大件数。これを超えたら `…` で打ち切る（G39 と同じ）。
    static let detailLimit = 50

    /// 報告するに値するか（値しないなら nil）を含めて文言を組む。
    ///
    /// - **成功だけなら流す**（`.info`）。監視フォルダは黙って動くものなので、うるさくしない。
    /// - **失敗・表紙失敗・中断があれば残す**（`.warning`）。
    ///   数秒で消えると、何が起きたか知る機会が永久に失われる。
    /// - `alreadyPresent` は**報告しない**。監視フォルダは同じファイルを何度も見るのでノイズになる。
    static func make(_ result: BookImporter.ImportResult) -> Notice? {
        var parts: [String] = []
        var details: [String] = []

        if !result.addedIDs.isEmpty {
            parts.append(String(localized: "\(result.addedIDs.count) 件を自動追加"))
        }
        if !result.failed.isEmpty {
            parts.append(String(localized: "\(result.failed.count) 件失敗"))
            details.append(String(localized: "取り込めなかったファイル:") + "\n"
                           + list(result.failed.map { "\($0.0.path): \($0.1.localizedDescription)" }))
        }
        if !result.coverFailures.isEmpty {
            parts.append(String(localized: "表紙なし \(result.coverFailures.count) 件"))
            details.append(String(localized: "表紙を作れなかったファイル:") + "\n"
                           + list(result.coverFailures.map(\.path)))
        }

        let isWarning = !result.failed.isEmpty || !result.coverFailures.isEmpty || result.cancelled
        guard !parts.isEmpty || result.cancelled else { return nil }

        // 中断は他の件数に**掛かる**情報なので、並べずに文の主語にする
        // （「3 件追加したが、全部は見ていない」）。件数を括弧に入れるのは、
        // 他の parts が体言止めの見出し調で、「中断しました。」（句点付きの完結した文）と
        // 直に繋ぐと文体が途中で切り替わって読みにくいため。
        // `parts` が空の場合と同じ文型に揃うという利点もある。
        let text: String
        if result.cancelled {
            text = parts.isEmpty
                ? String(localized: "取り込みを中断しました")
                : String(localized: "取り込みを中断しました（\(parts.joined(separator: " / "))）")
        } else {
            text = parts.joined(separator: " / ")
        }

        return Notice(kind: isWarning ? .warning : .info,
                      text: text,
                      detail: details.isEmpty ? nil : details.joined(separator: "\n\n"))
    }

    /// 行頭に `・` を付けて並べ、`detailLimit` を超えたら `…` で打ち切る。
    private static func list(_ lines: [String]) -> String {
        lines.prefix(detailLimit).map { "  ・\($0)" }.joined(separator: "\n")
            + (lines.count > detailLimit ? "\n  …" : "")
    }
}
