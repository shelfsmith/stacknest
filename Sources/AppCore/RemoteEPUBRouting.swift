// SPDX-License-Identifier: MIT
import Foundation

/// G48-3: リモート書庫の本を「テキスト EPUB（/file → Washi）」か「ページ経路（manifest/pages）」に振り分ける。
/// 判定の正はサーバの manifest（format == "epub"）。拡張子は二重の保険（サーバの format を拡張子が違う本に適用しない）。
public enum RemoteEPUBRouting {
    public enum Route: Equatable, Sendable { case textEPUB, pages }
    public static func route(filename: String?, manifestFormat: String) -> Route {
        guard let filename, (filename as NSString).pathExtension.lowercased() == "epub", manifestFormat == "epub" else { return .pages }
        return .textEPUB
    }
}
