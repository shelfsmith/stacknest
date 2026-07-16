// SPDX-License-Identifier: MIT
import Foundation

/// サーバ→クライアントのライブ変更イベント（SSE）。`library` は対象ライブラリ UUID。
public enum LiveEvent: Equatable, Sendable {
    case connected        // G13: クライアント側で SSE 接続確立時に合成（サーバは emit しない）
    case bookChanged(library: String, bookID: Int)
    case structureChanged(library: String)
    case settingsChanged(library: String)
    /// G12b-3b: メンテナンスジョブ（圧縮/メタデータ補完等）の進捗通知。
    case maintenanceProgress(library: String, job: String, done: Int, total: Int)
    /// G12b-3b: メンテナンスジョブの完了通知。outcome: "done"/"cancelled"/"failed"
    case maintenanceFinished(library: String, job: String, outcome: String, count: Int)

    /// G13: `.connected` はクライアント合成イベントで対象ライブラリを持たない。サーバは emit しない
    /// （EventHub.publish の scope フィルタにも渡らない）ため値は実質未使用だが、switch 網羅のため空文字を返す。
    public var library: String {
        switch self {
        case .connected: return ""
        case .bookChanged(let l, _), .structureChanged(let l), .settingsChanged(let l): return l
        case .maintenanceProgress(let l, _, _, _), .maintenanceFinished(let l, _, _, _): return l
        }
    }

    private var eventName: String {
        switch self {
        case .connected: return "connected"   // G13: サーバは emit しないため sseFrame() は実運用で呼ばれない
        case .bookChanged: return "bookChanged"
        case .structureChanged: return "structureChanged"
        case .settingsChanged: return "settingsChanged"
        case .maintenanceProgress: return "maintenanceProgress"
        case .maintenanceFinished: return "maintenanceFinished"
        }
    }

    private var jsonData: String {
        switch self {
        case .connected: return "{}"
        case .bookChanged(let l, let id):
            return #"{"library":\#(quote(l)),"bookId":\#(id)}"#
        case .structureChanged(let l), .settingsChanged(let l):
            return #"{"library":\#(quote(l))}"#
        case .maintenanceProgress(let l, let job, let done, let total):
            return #"{"library":\#(quote(l)),"job":\#(quote(job)),"done":\#(done),"total":\#(total)}"#
        case .maintenanceFinished(let l, let job, let outcome, let count):
            return #"{"library":\#(quote(l)),"job":\#(quote(job)),"outcome":\#(quote(outcome)),"count":\#(count)}"#
        }
    }

    /// SSE 1 フレーム（`event:` ＋ `data:` ＋ 空行）。
    public func sseFrame() -> String { "event: \(eventName)\ndata: \(jsonData)\n\n" }

    /// SSE の event 名＋data(JSON) から復号。未知イベント / 不正 JSON は nil。
    public static func decode(event: String, data: String) -> LiveEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let library = obj["library"] as? String else { return nil }
        switch event {
        case "bookChanged":
            guard let id = obj["bookId"] as? Int else { return nil }
            return .bookChanged(library: library, bookID: id)
        case "structureChanged": return .structureChanged(library: library)
        case "settingsChanged": return .settingsChanged(library: library)
        case "maintenanceProgress":
            guard let job = obj["job"] as? String, let done = obj["done"] as? Int, let total = obj["total"] as? Int else { return nil }
            return .maintenanceProgress(library: library, job: job, done: done, total: total)
        case "maintenanceFinished":
            guard let job = obj["job"] as? String, let outcome = obj["outcome"] as? String, let count = obj["count"] as? Int else { return nil }
            return .maintenanceFinished(library: library, job: job, outcome: outcome, count: count)
        default: return nil
        }
    }

    private func quote(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s], options: .fragmentsAllowed), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""   // ["x"] → "x"
    }
}
