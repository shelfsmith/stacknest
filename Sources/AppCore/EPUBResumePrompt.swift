// SPDX-License-Identifier: MIT
import EPUBAdapter

/// G54-S3b: EPUB を開いたときに「続きから読みますか？」を訊くかどうか。
/// 画像ビューアは保存ページが 0 より大きいときに訊く（`ViewerWindowController.showResumeDialogIfNeeded`）。
/// EPUB の位置はページ番号を持たない（spine ＋ 章内の進行率）ので、
/// **保存された位置が本の先頭でないこと**を同じ意味の条件として使う。
public enum EPUBResumePrompt {
    /// 保存された位置が無い、または本の先頭（最初の項目の先頭）なら訊かない。
    public static func shouldAsk(locator: EPUBLocatorValue?) -> Bool {
        guard let locator else { return false }
        if locator.spine > 0 { return true }
        return locator.progress > 0
    }
}
