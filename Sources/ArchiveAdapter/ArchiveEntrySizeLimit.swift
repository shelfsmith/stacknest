// SPDX-License-Identifier: MIT
import Foundation

/// アーカイブ1エントリあたりの展開後サイズ上限（decompression-bomb / メモリ枯渇 DoS 対策）。
///
/// 背景: `archive_entry_size(entry)` はアーカイブ内メタデータの自己申告値であり、攻撃者が
/// 自由に偽装できる。これを無条件に信頼して `Data(count: size)` で先行確保したり、逐次読み取りを
/// 無制限に `Data` へ積み増したりすると、悪意あるアーカイブ1エントリだけで OOM を誘発できる
/// （実データが小さくても宣言サイズだけ確保される／実データが巨大なら際限なく蓄積される）。
///
/// `maxEntryBytes` はどのような正当なカバー/ページ画像（数十MB級まで）よりも十分大きく、
/// OOM を招く前に安全側で棄却できる程度に小さい値として選定した。
public enum ArchiveEntrySizeLimit {
    /// 512 MiB — 単一エントリの展開後サイズ上限。
    public static let maxEntryBytes = 512 * 1024 * 1024

    /// 宣言サイズ（または逐次読み取りの累積サイズ）が上限を超えているかを判定する純関数。
    /// - Parameters:
    ///   - size: 判定対象のバイト数（エントリの宣言サイズ、または読み取り累積サイズ）。
    ///   - limit: 上限バイト数。省略時は `maxEntryBytes`（テストで注入可能にするため引数化）。
    public static func shouldReject(size: Int, limit: Int = maxEntryBytes) -> Bool {
        size > limit
    }
}
