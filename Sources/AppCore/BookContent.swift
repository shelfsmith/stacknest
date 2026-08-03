// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import ArchiveAdapter

/// 内蔵ビューアが書籍の中身を読むための抽象化（§5.5）。0-based page index。
public protocol BookContent: Sendable {
    var pageCount: Int { get async throws }
    func imageData(at page: Int) async throws -> Data
    /// 破損等で全ページを読み取れなかったときにユーザーへ出す注意文。正常なら nil。
    /// **既定は nil**（下の extension）なので、打ち切りが起こり得ない実装は何もしなくてよい。
    var damageNote: String? { get async }
}

public extension BookContent {
    var damageNote: String? { get async { nil } }
}

/// BookContent 生成・取得のエラー。
public enum BookContentError: Error, Sendable, Equatable {
    case invalidPath(String)
    case unsupported(BookCategory)
    case pageOutOfRange(Int)
    /// 範囲内ページの描画失敗（範囲外は pageOutOfRange）。HTTP 写像では 500 相当（4.1a）。
    case renderFailed(Int)
    case pdfUnopenable(String)
}

/// BookRow から適切な BookContent を生成する。
public enum BookContentFactory {
    /// `BookCategory.classify(path:)` で種別を振り分けて BookContent を返す。
    /// 動画・非対応・パス無しは throw（呼び出し側が外部ビューアにフォールバック）。
    public static func make(for book: BookRow) throws -> BookContent {
        guard let path = book.path, !path.isEmpty else {
            throw BookContentError.invalidPath(book.path ?? "(nil)")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw BookContentError.invalidPath(path)
        }
        let url = URL(fileURLWithPath: path)
        let category = BookCategory.classify(path: path)
        switch category {
        case .archive:
            return ArchiveBookContent(url: url)
        case .folder:
            return FolderBookContent(url: url)
        case .image:
            return SingleImageBookContent(url: url)
        case .text:
            if url.pathExtension.lowercased() == "pdf" {
                guard let pdf = PDFBookContent(url: url) else {
                    throw BookContentError.pdfUnopenable(path)
                }
                return PDFPageContent(pdf: pdf)
            }
            throw BookContentError.unsupported(category)
        case .video:
            throw BookContentError.unsupported(category)
        }
    }
}

/// zip/cbz/cbr/7z を libarchive 経由で逐次デコード。
/// 画像エントリが 0 件の場合は zip 内 PDF への fallback を試みる
/// （取込側 BookAddCoordinator の PDF fallback と同等の挙動・smoke 2026-06-10 ⑥）。
/// PDF は一時ファイルに展開して `PDFBookContent` でレンダリングし、
/// 一時ファイルは deinit で削除する。actor のため PDFDocument アクセスは直列化される。
public actor ArchiveBookContent: BookContent {
    private let url: URL
    private let extractor = LibarchiveCoverExtractor()
    private var entryNames: [String]?
    /// 直近の列挙で打ち切りが起きたか（`loadEntries()` が設定する）。
    private var listingTruncated = false
    /// G18 C5: ページ取得を「毎回開き直して線形スキャン（O(N)）」から「開いたまま順方向 1 パス
    /// ＋抽出キャッシュ」へ。本 1 冊につき 1 インスタンスを遅延生成し全ページ取得を集約する。
    private var seqExtractor: SequentialArchiveExtractor?
    private var pdfFallback: PDFBookContent?
    private var pdfFallbackResolved = false
    private var pdfTempURL: URL?

    public init(url: URL) { self.url = url }

    deinit {
        if let tmp = pdfTempURL {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// 進行中の列挙。`loadEntries()` の再入 caller はこれを await して**同一の走査結果**を共有する。
    private var entriesTask: Task<ArchiveListing, Error>?

    /// G26 Codex Minor #3: `listImageEntries` の await は actor の再入点なので、素朴に書くと
    /// 複数 caller（pageCount / imageData / damageNote が並行に走る）がそれぞれ別の走査を始め、
    /// `entryNames` と `listingTruncated` が**別々の走査の結果で上書きされうる**
    /// （読んでいる最中にファイルが差し替われば、names は健全なのに truncated だけ true 等）。
    /// 走査は 1 本の Task に集約し、コミットは await 後の同期区間で 1 度だけ行う
    /// （先にコミットした caller が居ればその結果に従う — `resolvePDFFallback` と同じ流儀）。
    private func loadEntries() async throws -> [String] {
        if let names = entryNames { return names }
        if entriesTask == nil {
            entriesTask = Task { [extractor, url] in
                try await extractor.listImageEntries(in: url)
            }
        }
        let listing: ArchiveListing
        do {
            listing = try await entriesTask!.value
        } catch {
            // 失敗はキャッシュしない（従来どおり次回呼び出しで再試行できる）。
            entriesTask = nil
            throw error
        }
        // 以降 suspension なし＝actor 上アトミック。
        if let names = entryNames { return names }   // 再入した別 caller が先にコミット済み
        entryNames = listing.names
        listingTruncated = listing.truncated
        return listing.names
    }

    public var damageNote: String? {
        get async {
            guard let names = try? await loadEntries(), listingTruncated else { return nil }
            return "⚠ このファイルは破損しています。\(names.count) ページまで読み込みました"
        }
    }

    private var pdfDataTask: Task<Data?, Error>?

    /// 画像エントリ 0 件のときのみ、zip 内 PDF を一時ファイルへ展開して開く。
    /// actor 再入対策: 抽出は共有 Task に集約し、コミット（resolved/temp/fallback の確定）は
    /// await 後の同期区間で行う（先にコミットした caller が居れば従う）。
    private func resolvePDFFallback() async throws -> PDFBookContent? {
        if pdfFallbackResolved { return pdfFallback }
        if pdfDataTask == nil {
            pdfDataTask = Task { [extractor, url] in
                try await extractor.extractFirstPDFData(in: url)
            }
        }
        let data = try await pdfDataTask!.value
        if pdfFallbackResolved { return pdfFallback }   // 再入した別 caller が先にコミット済み
        pdfFallbackResolved = true
        guard let data else { return nil }
        // 以降 suspension なし＝actor 上アトミック
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        guard let pdf = PDFBookContent(url: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        pdfTempURL = tmp
        pdfFallback = pdf
        return pdf
    }

    public var pageCount: Int {
        get async throws {
            let names = try await loadEntries()
            if !names.isEmpty { return names.count }
            return try await resolvePDFFallback()?.pageCount ?? 0
        }
    }

    public func imageData(at page: Int) async throws -> Data {
        let names = try await loadEntries()
        if !names.isEmpty {
            guard page >= 0, page < names.count else {
                throw BookContentError.pageOutOfRange(page)
            }
            // G18 C5: stateless な per-page 再オープン（O(N)）ではなく、開きっぱなしの順方向
            // リーダーへ集約する（深いページでも一定コスト・矢印長押しのスムーズさを担保）。
            if seqExtractor == nil {
                seqExtractor = SequentialArchiveExtractor(url: url, imageNames: Set(names))
            }
            return try await seqExtractor!.data(forName: names[page])
        }
        // PDF fallback 経路: 範囲チェックを先に行い、範囲内の描画失敗は renderFailed に分離（4.1a）
        guard let pdf = try await resolvePDFFallback() else {
            throw BookContentError.pageOutOfRange(page)
        }
        guard page >= 0, page < pdf.pageCount else {
            throw BookContentError.pageOutOfRange(page)
        }
        guard let data = pdf.pageImageData(at: page, maxPixelSize: 3200) else {
            throw BookContentError.renderFailed(page)
        }
        return data
    }
}

/// フォルダ内画像をファイル名 natural sort 順で列挙。
public actor FolderBookContent: BookContent {
    private let url: URL
    private let extractor = FolderCoverExtractor()
    private var entryNames: [String]?

    public init(url: URL) { self.url = url }

    private func loadEntries() async throws -> [String] {
        if let names = entryNames { return names }
        let names = try await extractor.listImageEntries(in: url).names
        entryNames = names
        return names
    }

    public var pageCount: Int {
        get async throws { try await loadEntries().count }
    }

    public func imageData(at page: Int) async throws -> Data {
        let names = try await loadEntries()
        guard page >= 0, page < names.count else {
            throw BookContentError.pageOutOfRange(page)
        }
        let fileURL = url.appendingPathComponent(names[page])
        return try Data(contentsOf: fileURL)
    }
}

/// 単一画像ファイル（pageCount==1）。
public struct SingleImageBookContent: BookContent {
    private let url: URL
    public init(url: URL) { self.url = url }

    public var pageCount: Int { get async throws { 1 } }

    public func imageData(at page: Int) async throws -> Data {
        guard page == 0 else { throw BookContentError.pageOutOfRange(page) }
        return try Data(contentsOf: url)
    }
}

/// PDF（PDFBookContent を任意ページ画像化）。
/// Phase 4.0: `PDFBookContent` の描画が CG 化され main thread 非依存になったため、
/// MainActor 閉じ込めを廃止し actor に変更。非 Sendable な `PDFDocument` への
/// アクセスは actor executor が直列化する（@unchecked Sendable も不要になった）。
/// GUI スレッドを塞がないため、内蔵ビューアと 4.1a LibraryServer の双方から安全に呼べる。
/// 注意: 表示中の `PDFView` と同一の `PDFDocument` インスタンスを共有しないこと
/// （PDFKit はドキュメント単位で非スレッドセーフ。本 actor は自前で開いた document 専用）。
public actor PDFPageContent: BookContent {
    private let pdf: PDFBookContent
    public init(pdf: PDFBookContent) { self.pdf = pdf }

    public var pageCount: Int {
        get async throws { pdf.pageCount }
    }

    public func imageData(at page: Int) async throws -> Data {
        // 範囲チェックを先に行い、範囲内の描画失敗は renderFailed に分離（4.1a・HTTP 404/500 写像）
        let count = pdf.pageCount
        guard page >= 0, page < count else {
            throw BookContentError.pageOutOfRange(page)
        }
        // Retina 実効解像度の維持（旧 lockFocus 実装は backing scale 2x で実質 3200px を
        // 出力しており、1600 だと HiDPI 表示で従来よりソフトになる — smoke 2026-06-10 ②）
        guard let data = pdf.pageImageData(at: page, maxPixelSize: 3200) else {
            throw BookContentError.renderFailed(page)
        }
        return data
    }
}
