// SPDX-License-Identifier: MIT
import Foundation

public enum LastReadBook: Codable, Equatable, Sendable {
    case local(bundlePath: String, bookID: Int, title: String)
    case remote(serverID: UUID, serverURL: String, libraryUUID: String, libraryName: String, bookID: Int, title: String, locked: Bool)
    case offline(bookID: Int, title: String)

    public var title: String {
        switch self {
        case .local(_, _, let t), .offline(_, let t): return t
        case .remote(_, _, _, _, _, let t, _): return t
        }
    }
}

/// アプリ全体で「最後に開いた本」1冊を記録・永続する（UserDefaults JSON）。
@MainActor
public final class LastReadTracker {
    public static let shared = LastReadTracker()
    private let defaults: UserDefaults
    private static let key = "stacknest.lastReadBook"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var last: LastReadBook? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(LastReadBook.self, from: data)
    }

    public func record(_ ref: LastReadBook) {
        if let data = try? JSONEncoder().encode(ref) { defaults.set(data, forKey: Self.key) }
    }
}
