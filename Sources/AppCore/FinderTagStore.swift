// SPDX-License-Identifier: MIT
import Foundation

/// Finder タグ（`com.apple.metadata:_kMDItemUserTags`）の読み書き。
///
/// **ユーザーのファイルに書き込む。**`apply(names:to:)` は既存タグの**色番号を保つ**ことが要件
/// （spec §4.3）。素朴に名前だけ書き戻すと、Finder 上の色が全部消える。
///
/// xattr は**シンボリックリンクを辿る**（options = 0）。`xattr(1)` と Finder の既定に揃えてあり、
/// リンク先の実ファイルのタグを読み書きする。読みと書きで必ず同じ options を使うこと。
public enum FinderTagStore {
    static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    public static func read(at url: URL) throws -> [FinderTagEntry] {
        guard let data = try readAttribute(at: url), !data.isEmpty else { return [] }
        guard let raw = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String] else { return [] }
        return raw.map(FinderTagEntry.parse)
    }

    public static func write(_ entries: [FinderTagEntry], to url: URL) throws {
        guard !entries.isEmpty else { try removeAttribute(at: url); return }
        let data = try PropertyListSerialization.data(
            fromPropertyList: entries.map(\.rawValue), format: .binary, options: 0)
        try writeAttribute(data, at: url)
    }

    /// 名前の集合を `names` に合わせる。**残るタグの色番号は既存のものを引き継ぐ。**
    /// 新しく足すタグは色無し（StackNest 側に色の概念が無いため）。
    public static func apply(names: Set<String>, to url: URL) throws {
        let existing = try read(at: url)
        // ★ 既にあるタグは**並び順もそのまま**残す。Finder はタグの順序を保持しており、
        // 同期のたびに並べ替えるのは「触る必要のないユーザーデータを変える」ことになる。
        // 色番号を引き継ぐのと同じ理由で、こちらが決めてよい値ではない。
        var entries = existing.filter { names.contains($0.name) }
        // 増えた分だけを末尾に足す。新しいタグ同士は並びが決まらないので、
        // 毎回同じバイト列になるようソートしておく（無意味な書き込みを避けられる）。
        let existingNames = Set(existing.map(\.name))
        entries += names.subtracting(existingNames).sorted().map {
            FinderTagEntry(name: $0, colorIndex: nil)
        }
        try write(entries, to: url)
    }

    // MARK: - xattr

    /// サイズ問い合わせ → 本読みの 2 回呼び。**その間に他プロセス（Finder）がタグを変えうる。**
    /// 縮んだ場合は戻り値 `got` が実長なので問題ないが、伸びた場合は `ERANGE` で失敗するため
    /// 数回だけ問い直す。無限には回さない（ずっと書き換え続けられている状況は異常なので投げる）。
    private static func readAttribute(at url: URL) throws -> Data? {
        try url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { throw FinderTagError.badPath(url.path) }
            for _ in 0..<8 {
                let size = getxattr(path, attributeName, nil, 0, 0, 0)
                if size < 0 {
                    let e = errno
                    if e == ENOATTR { return nil }
                    throw FinderTagError.xattrFailed(errno: e, path: url.path)
                }
                if size == 0 { return Data() }
                var buf = [UInt8](repeating: 0, count: size)
                let got = getxattr(path, attributeName, &buf, size, 0, 0)
                if got >= 0 { return Data(buf[0..<got]) }
                let e = errno
                if e == ENOATTR { return nil }
                if e == ERANGE { continue }  // 読む直前に伸びた。サイズを問い直す。
                throw FinderTagError.xattrFailed(errno: e, path: url.path)
            }
            throw FinderTagError.xattrFailed(errno: ERANGE, path: url.path)
        }
    }

    private static func writeAttribute(_ data: Data, at url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw FinderTagError.badPath(url.path) }
            // errno は失敗した呼び出しの直後に読む（間に何も挟まないよう closure 内で捕まえる）。
            var failure: Int32 = 0
            let r = data.withUnsafeBytes { raw -> Int32 in
                let rc = setxattr(path, attributeName, raw.baseAddress, raw.count, 0, 0)
                failure = errno
                return rc
            }
            if r < 0 { throw FinderTagError.xattrFailed(errno: failure, path: url.path) }
        }
    }

    private static func removeAttribute(at url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw FinderTagError.badPath(url.path) }
            let r = removexattr(path, attributeName, 0)
            let e = errno
            // 元から無いのは成功と同じ（消したい状態になっている）。
            if r < 0 && e != ENOATTR {
                throw FinderTagError.xattrFailed(errno: e, path: url.path)
            }
        }
    }
}

public enum FinderTagError: Error, Equatable {
    case xattrFailed(errno: Int32, path: String)
    case badPath(String)
}
