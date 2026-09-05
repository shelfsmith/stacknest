// SPDX-License-Identifier: MIT
import EPUBAdapter   // このファイルは WashiCore を import しない（同名型と衝突させないための別名定義）

/// Washi 1.16.0 が `EPUBReadingDirection` を追加し、契約側の同名型と衝突するようになった。
/// `EPUBAdapter.EPUBReadingDirection` はモジュールではなく登録点の enum `EPUBAdapter` に解決されるため、
/// WashiCore を見えないこのファイルで契約型に別名を付けて、アダプタ内ではこちらを使う。
typealias ContractReadingDirection = EPUBReadingDirection
