// SPDX-License-Identifier: MIT
/// 登録点。合成点（App の起動時）で `EPUBAdapter.reader = WashiEPUBReader()` と 1 行書く。
/// 未登録なら EPUB の表紙は「作れない」経路に落ちる（クラッシュしない）。
public enum EPUBAdapter {
    nonisolated(unsafe) public static var reader: (any EPUBReading)?
}
