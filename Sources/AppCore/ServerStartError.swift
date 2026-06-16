// SPDX-License-Identifier: MIT
import Foundation

/// 共有サーバ起動失敗の分類。EADDRINUSE（ポート使用中）を判別する。
public enum ServerStartError: Equatable, Sendable {
    case portInUse(Int)
    case generic(String)

    public static func classify(_ error: Error, port: Int) -> ServerStartError {
        if let posix = error as? POSIXError, posix.code == .EADDRINUSE {
            return .portInUse(port)
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EADDRINUSE) {
            return .portInUse(port)
        }
        let desc = "\(error)".lowercased()
        if desc.contains("address already in use") || desc.contains("errno: 48") || desc.contains("eaddrinuse") {
            return .portInUse(port)
        }
        return .generic(error.localizedDescription)
    }

    public var message: String {
        switch self {
        case .portInUse(let p):
            return "ポート \(p) は使用中です。別のアプリ/サービスが使用している可能性があります。ポート番号を変更するか「ランダム」を押して再起動してください。"
        case .generic(let m):
            return m
        }
    }
}
