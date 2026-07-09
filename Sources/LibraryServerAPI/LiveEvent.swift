// SPDX-License-Identifier: MIT
import Foundation

/// サーバ→クライアントのライブ変更イベント（SSE）。`library` は対象ライブラリ UUID。
public enum LiveEvent: Equatable, Sendable {
    case bookChanged(library: String, bookID: Int)
    case structureChanged(library: String)
    case settingsChanged(library: String)

    public var library: String {
        switch self {
        case .bookChanged(let l, _), .structureChanged(let l), .settingsChanged(let l): return l
        }
    }

    private var eventName: String {
        switch self {
        case .bookChanged: return "bookChanged"
        case .structureChanged: return "structureChanged"
        case .settingsChanged: return "settingsChanged"
        }
    }

    private var jsonData: String {
        switch self {
        case .bookChanged(let l, let id):
            return #"{"library":\#(quote(l)),"bookId":\#(id)}"#
        case .structureChanged(let l), .settingsChanged(let l):
            return #"{"library":\#(quote(l))}"#
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
        default: return nil
        }
    }

    private func quote(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s], options: .fragmentsAllowed), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""   // ["x"] → "x"
    }
}
