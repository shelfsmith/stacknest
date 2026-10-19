// SPDX-License-Identifier: MIT
import Foundation
import StackNestViewerKitCore

/// G60 v3: 外部ビューアのアプリが `Contents/Info.plist` に置く、StackNest への対応の宣言（spec §5.6）。
///
///     <key>StackNestViewerSupport</key>
///     <dict>
///       <key>referenceFormatVersions</key>
///       <array><integer>1</integer></array>
///     </dict>
///
/// キーの名前と版の読み方は StackNestViewerKit の `StackNestViewerSupport`（ビューアが自分の宣言を点検するときと
/// 同じ解釈・G63 段 4）。判定はこの専用のキーだけで行う。参照ファイルの型（UTType・拡張子）を開けるという宣言は
/// 使わない（`*` や `public.json` を開けると宣言しているだけのアプリを紛れ込ませないため。v2 の判定を置き換えた）。
/// plist は `PropertyListSerialization` で毎回直接読む（`Bundle(url:)` はキャッシュするので使わない。
/// LaunchServices の登録にも頼らない）。
public struct ViewerSupportDeclaration: Sendable, Equatable {
    /// `CFBundleIdentifier`（無ければ nil）。確認できた対応ビューアの記録の鍵に使う。
    public let bundleIdentifier: String?
    /// 画面に出す名前（`CFBundleDisplayName` → `CFBundleName` → `.app` を除いたファイル名）。
    public let displayName: String
    /// 宣言された版（正の整数だけ・宣言の順）。キーが無い・形が違うなら空。
    public let referenceFormatVersions: [Int]

    public init(bundleIdentifier: String?, displayName: String, referenceFormatVersions: [Int]) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.referenceFormatVersions = referenceFormatVersions
    }

    /// 参照ファイルに書く版。宣言と StackNest が書ける版（`BookReferences.writableVersions`）の共通の最大。
    /// 共通の版が無い（＝未対応）なら nil。
    public var chosenFormatVersion: Int? {
        StackNestViewerSupport.chooseVersion(declared: referenceFormatVersions, writable: BookReferences.writableVersions)
    }

    /// `appURL` の `Contents/Info.plist` を読む。plist が無い・読めない・辞書でないなら nil。
    /// 宣言のキーが無いだけなら、版が空の宣言を返す（設定の「未対応」の表示に名前を使うため）。
    public static func read(appURL: URL) -> ViewerSupportDeclaration? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        else { return nil }
        let displayName = nonEmptyString(plist["CFBundleDisplayName"])
            ?? nonEmptyString(plist["CFBundleName"])
            ?? appURL.deletingPathExtension().lastPathComponent
        return ViewerSupportDeclaration(bundleIdentifier: nonEmptyString(plist["CFBundleIdentifier"]),
                                        displayName: displayName,
                                        referenceFormatVersions: StackNestViewerSupport.declaredVersions(in: plist))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// G60 v3: 参照ファイルを渡せる外部ビューア（実在し、宣言に StackNest が書ける版がある）。
public struct ReferenceViewer: Sendable, Equatable {
    public let appURL: URL
    public let declaration: ViewerSupportDeclaration
    /// 参照ファイルの `version` に書く版（`ViewerSupportDeclaration.chosenFormatVersion`）。
    public let formatVersion: Int

    /// 同じアプリで同じ版を書くか（複数の本を 1 回の `open` にまとめる単位）。アプリの場所は書き方の違い
    /// （末尾の `/`・`.` や `..`）を揃えて比べる（`==` は宣言の中身まで比べ、URL の書き方の違いで別のビューアになる）。
    public func isSameApp(as other: ReferenceViewer) -> Bool {
        formatVersion == other.formatVersion
            && appURL.standardizedFileURL.path == other.appURL.standardizedFileURL.path
    }

    /// 宣言を読み、対応していれば返す（未対応・読めないなら nil）。
    public static func resolve(appURL: URL) -> ReferenceViewer? {
        guard let declaration = ViewerSupportDeclaration.read(appURL: appURL),
              let version = declaration.chosenFormatVersion else { return nil }
        return ReferenceViewer(appURL: appURL, declaration: declaration, formatVersion: version)
    }
}
