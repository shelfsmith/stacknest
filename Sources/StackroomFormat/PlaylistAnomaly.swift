// SPDX-License-Identifier: MIT
import Foundation

/// G49: `Playlists` 配列の 1 要素が読めなかったことの記録。
/// 以前は配列全体を `try?` で握り潰していたため、1 件の破損で**全シェルフが消えて**いた（外部からの報告 PR #2）。
public enum PlaylistAnomaly: Error, LocalizedError, Equatable, Sendable {
    case malformedPlaylistEntry(index: Int, underlying: String)
    case unreadableConditions(title: String)
    /// `Playlists` キーはあったが配列ではなかった。以前はここも黙って 0 件になり、
    /// 「シェルフの無い書庫」と見分けが付かなかった。
    case playlistsNotAnArray(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .malformedPlaylistEntry(let index, let underlying):
            return "Playlists entry #\(index) could not be decoded: \(underlying)"
        case .unreadableConditions(let title):
            return "Playlist '\(title)': smart-shelf conditions could not be decoded and were dropped"
        case .playlistsNotAnArray(let underlying):
            return "Playlists is present but is not an array, so no shelf could be read: \(underlying)"
        }
    }
}
