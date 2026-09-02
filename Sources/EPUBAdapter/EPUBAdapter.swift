// SPDX-License-Identifier: MIT
/// 登録点。合成点（App の起動時）で `EPUBAdapter.reader = WashiEPUBReader()` と 1 行書く。
/// 未登録なら EPUB の表紙は「作れない」経路に落ちる（クラッシュしない）。
public enum EPUBAdapter {
    /// `nonisolated(unsafe)` の根拠: 合成点（App 起動時）で一度だけ書き、以後は読み取りのみ。
    /// 書き込みが 1 箇所・起動時に限られるため、この変数についてデータ競合は起きない。
    nonisolated(unsafe) public static var reader: (any EPUBReading)?
}
