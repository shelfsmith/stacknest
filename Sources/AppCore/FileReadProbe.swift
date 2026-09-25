// SPDX-License-Identifier: MIT
import Foundation

/// ファイルアクセスの 3 状態判定結果（G54-S3e: `AppState.ReadProbe` をここへ移した。巻送りの事前確認
/// `VolumeHandover` と SPM のテストから使うため。App 側は `AppState.ReadProbe` の別名で従来どおり使える）。
/// - readable: 実アクセスできる（TCC 含む）
/// - notFound: 不在（移動/削除・ENOENT）
/// - noPermission: 存在するが読めない（TCC/権限拒否・EPERM/EACCES 等）
public enum FileReadProbe: Equatable, Sendable {
    case readable, notFound, noPermission

    /// ファイルの実アクセスを試み、可読/不在/権限不足を判別する。1 バイト読んで close。
    /// 不在(ENOENT)と権限拒否(EPERM/EACCES)を errno で区別し、移動・削除された
    /// ファイルに対して誤って「フォルダ許可」導線を出さないためのもの（V5 修正）。
    public static func check(_ url: URL) -> FileReadProbe {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // フォルダ型の本は path がディレクトリ。read() は EISDIR で失敗するので、
            // ディレクトリは「列挙できるか」で可読判定する（TCC で塞がれたディレクトリは
            // contentsOfDirectory が throw→権限不足として許可導線に乗る）。
            do { _ = try FileManager.default.contentsOfDirectory(atPath: url.path); return .readable }
            catch { return isNoSuchFileError(error) ? .notFound : .noPermission }
        }
        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            _ = try fh.read(upToCount: 1)
            return .readable
        } catch {
            return isNoSuchFileError(error) ? .notFound : .noPermission
        }
    }

    /// error が「ファイル不在(ENOENT / NSFileReadNoSuchFileError)」を表すか。
    /// TCC/権限拒否は EPERM/EACCES→NSFileReadNoPermissionError となり、ここでは false。
    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           u.domain == NSPOSIXErrorDomain, u.code == Int(ENOENT) { return true }
        return false
    }
}
