// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore  // TextNormalize

/// 巻数をファイル名に書くときの桁数。
///
/// **最低 2 桁。**シリーズ内の最大巻が 3 桁なら 3 桁にする（`07` と `007` が混ざらないように）。
/// 目的は**ディスク上に既に並んでいるファイルと桁を揃えること**なので、
/// 最大巻は改名対象の中からではなく**庫全体から**引く（`Database.maxVolumeBySeries`）。
public enum VolumeWidth {
    public static let minimum = 2

    /// シリーズ内の最大巻から桁数を決める。
    public static func width(forMax max: Double?) -> Int {
        guard let max, max >= 1 else { return minimum }
        let digits = String(Int(max.rounded(.towardZero))).count
        return Swift.max(minimum, digits)
    }

    /// `[シリーズ名: 最大巻]` を `[シリーズ名: 桁]` にする。
    /// **鍵は NFC 正規化する** —— 素の文字列で突き合わせると、
    /// 濁点の合成が違うだけで桁が既定の 2 に落ちる。
    public static func widths(fromMaxVolumes maxes: [String: Double]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (series, max) in maxes {
            out[TextNormalize.nfc(series)] = width(forMax: max)
        }
        return out
    }
}
