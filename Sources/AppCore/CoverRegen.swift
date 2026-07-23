// SPDX-License-Identifier: MIT
import Foundation

/// cover 再生成（`AppState.regenerateThumbnail`／`refreshCoverAndPageCount`）の guard/fallback 判定を
/// App ターゲットから切り出した純ロジック。App ターゲットは単体テスト対象外のため、判定表をここで
/// テスト可能にする（サーバ側の `CoverRegenOutcome` と対をなすローカル側の明文化）。
public enum CoverRegen {
    /// エントリ時の外部表紙判定。
    public enum ExternalEntry: Equatable {
        case notExternal        // 通常 auto/manual → そのまま抽出
        case preserveExternal   // external かつサムネ現存 → no-op（保護・早期 return）
        case fallbackToAuto     // external かつサムネ不在 → auto へフォールバック（preferredName=nil）
    }

    public static func classifyEntry(wasExternal: Bool, externalThumbnailExists: Bool) -> ExternalEntry {
        guard wasExternal else { return .notExternal }
        return externalThumbnailExists ? .preserveExternal : .fallbackToAuto
    }

    /// 抽出後・書き込み直前のガード。external race を最優先で弾き、次に stale relink、どちらも
    /// なければ書いてよい。
    public enum WriteDecision: Equatable { case write, skipExternalRace, skipStaleRelink }

    public static func writeDecision(
        liveIsExternal: Bool, liveThumbnailExists: Bool,
        snapshotPath: String?, livePath: String?
    ) -> WriteDecision {
        if liveIsExternal && liveThumbnailExists { return .skipExternalRace }
        if livePath != snapshotPath { return .skipStaleRelink }
        return .write
    }

    /// ページ数書き込みのガード（stale relink 中に古い source の枚数で上書きしない）。
    public static func shouldWritePageCount(snapshotPath: String?, livePath: String?) -> Bool {
        livePath == snapshotPath
    }
}
