// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import ArchiveAdapter

/// 内蔵ビューワが書籍の中身を読むための抽象化（§5.5）。0-based page index。
public protocol BookContent: Sendable {
    var pageCount: Int { get async throws }
    func imageData(at page: Int) async throws -> Data
}

/// BookContent 生成・取得のエラー。
public enum BookContentError: Error, Sendable, Equatable {
    case invalidPath(String)
    case unsupported(BookCategory)
    case pageOutOfRange(Int)
    case pdfUnopenable(String)
}

/// BookRow から適切な BookContent を生成する。
public enum BookContentFactory {
    /// `BookCategory.classify(path:)` で種別を振り分けて BookContent を返す。
    /// 動画・非対応・パス無しは throw（呼び出し側が外部ビューワにフォールバック）。
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
public actor ArchiveBookContent: BookContent {
    private let url: URL
    private let extractor = LibarchiveCoverExtractor()
    private var entryNames: [String]?

    public init(url: URL) { self.url = url }

    private func loadEntries() async throws -> [String] {
        if let names = entryNames { return names }
        let names = try await extractor.listImageEntries(in: url)
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
        return try await extractor.imageData(in: url, entryName: names[page])
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
        let names = try await extractor.listImageEntries(in: url)
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
/// PDFKit (`PDFDocument`/`PDFPage.draw`) と `NSImage.lockFocus` は main thread 専用のため、
/// pageCount / imageData とも MainActor 上で実行する。`@unchecked Sendable` は、唯一の格納
/// プロパティ `pdf` が非 Sendable な PDFBookContent であることに対する明示的なエスケープ —
/// レンダリングを MainActor.run に閉じ込めることで実質的なスレッド安全性を担保する。
public struct PDFPageContent: BookContent, @unchecked Sendable {
    private let pdf: PDFBookContent
    public init(pdf: PDFBookContent) { self.pdf = pdf }

    public var pageCount: Int {
        get async throws {
            await MainActor.run { pdf.pageCount }
        }
    }

    public func imageData(at page: Int) async throws -> Data {
        try await MainActor.run {
            guard let data = pdf.pageImageData(at: page, maxPixelSize: 1600) else {
                throw BookContentError.pageOutOfRange(page)
            }
            return data
        }
    }
}
