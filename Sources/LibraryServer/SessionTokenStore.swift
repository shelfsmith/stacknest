// SPDX-License-Identifier: MIT
import Foundation

/// G23 (#9/#10): URL クエリに載せるための短命トークン。
///
/// `EventSource` と `<img>` はカスタムヘッダを送れないため、認証情報を URL に置かざるを得ない。
/// そこに**永続の grant token** をそのまま載せるとブラウザ履歴やプロキシログに残り続けるので、
/// 短命なセッショントークンへ交換してからクエリに載せる。
///
/// 設計は `LibraryTokenStore`（ロック庫の `lt`）と同じ: TTL 付き・メモリのみ・サーバ再起動で失効。
/// あちらは既にこの形だったのに、grant token だけがこの設計から漏れていた。
actor SessionTokenStore {
    private struct Entry { let grantToken: String; let expiresAt: ContinuousClock.Instant }
    private var entries: [String: Entry] = [:]
    private let ttl: Duration
    private let clock = ContinuousClock()

    /// 既定 TTL（秒）。`SessionReply.expiresIn` としてクライアントへ返す値と共有する。
    static let defaultTTLSeconds = 30 * 60

    init(ttl: Duration = .seconds(defaultTTLSeconds)) { self.ttl = ttl }

    /// grant token に対する短命トークンを発行する。
    func issue(grantToken: String) -> String {
        entries = entries.filter { $0.value.expiresAt > clock.now }   // 期限切れ掃除
        let token = UUID().uuidString + "-" + UUID().uuidString
        entries[token] = Entry(grantToken: grantToken, expiresAt: clock.now + ttl)
        return token
    }

    /// 有効なら元の grant token を返す。期限切れ／未知は nil。
    func resolve(_ session: String) -> String? {
        guard let e = entries[session], e.expiresAt > clock.now else { return nil }
        return e.grantToken
    }
}
