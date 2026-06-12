// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import Foundation
import LibraryServerAPI
import LibraryStore
import Observation
import RemoteClient
import os

/// Phase 4.2b-1: リモートライブラリ 1 個分の閲覧状態。
/// ローカルの AppState に相当する軽量モデル（書き込みはせず読み取り+進捗 POST のみ）。
@Observable
@MainActor
final class RemoteLibraryState {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "RemoteLibrary")

    let client: RemoteLibraryClient
    let libraryUUID: String
    var libraryName: String
    var locked: Bool
    var libraryToken: String?

    /// Phase 4.2b-1b-1 Task 3: 表示モード + per のグローバル設定（UserDefaults 永続）。
    private let prefs = RemoteBrowsePreferences()

    var books: [BookListItemDTO] = []
    var total = 0
    var page = 1
    var per: Int
    var query = ""
    var sortKey = "title"
    var ascending = true
    var isGrid = false
    var selection: Int? = nil
    var errorText: String? = nil

    /// 表示モード（paged / infinite）。setMode 経由で変更・永続化する。
    var scrollMode: RemoteScrollMode

    /// infinite スクロールの多重 loadMore を防ぐガード。
    private var isLoadingMore = false

    /// infinite モードの 1 チャンク件数（paged の per とは独立した固定値）。
    private let infiniteChunkSize = 100

    let coverCache = RemoteCoverCache()

    /// ビューワを 1 ウィンドウだけ保持する（ローカル AppState.viewerController と同じ方針）。
    private var viewerController: ViewerWindowController?

    init(client: RemoteLibraryClient, libraryUUID: String, libraryName: String, locked: Bool, libraryToken: String? = nil) {
        self.client = client
        self.libraryUUID = libraryUUID
        self.libraryName = libraryName
        self.locked = locked
        self.libraryToken = libraryToken
        self.per = prefs.perPageSize
        self.scrollMode = prefs.scrollMode
    }

    var pageCountTotalPages: Int { remoteTotalPages(total: total, per: per) }

    // MARK: - Mode / per control

    /// 表示モードを切り替えて永続化し、先頭から読み直す。
    func setMode(_ m: RemoteScrollMode) {
        scrollMode = m
        prefs.scrollMode = m
        Task { await reload() }
    }

    /// paged の per を 20...500 にクランプして永続化し、先頭から読み直す。
    func setPer(_ n: Int) {
        per = clampRemotePerPage(n)
        prefs.perPageSize = per
        Task { await reload() }
    }

    // MARK: - Loading

    /// 現在の取得サイズ（infinite は固定チャンク、paged は per）。
    private var fetchSize: Int { scrollMode == .infinite ? infiniteChunkSize : per }

    /// 指定ページ・サイズで 1 チャンク取得する（load/reload/loadMore 共通）。
    private func fetchChunk(page: Int, size: Int) async throws -> BookPageDTO {
        try await client.fetchBooks(
            libraryUUID: libraryUUID,
            query: query.isEmpty ? nil : query,
            sort: sortKey,
            ascending: ascending,
            page: page,
            per: size,
            libraryToken: libraryToken
        )
    }

    /// paged のページ送り。現在の page を per サイズで取得し books を置換する。
    func load() async {
        do {
            let result = try await fetchChunk(page: page, size: per)
            books = result.items
            total = result.total
            errorText = nil
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "読み込みに失敗しました"
        }
    }

    /// 先頭から読み直す（query/sort/ascending/mode/per 変更時）。books を置換する。
    func reload() async {
        page = 1
        books = []
        do {
            let result = try await fetchChunk(page: 1, size: fetchSize)
            books = result.items
            total = result.total
            errorText = nil
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "読み込みに失敗しました"
        }
    }

    /// infinite モードで末尾到達時に次チャンクを追記する。
    func loadMore() async {
        guard !isLoadingMore,
              scrollMode == .infinite,
              remoteNeedsNextChunk(loadedCount: books.count, total: total)
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let nextPage = page + 1
            let result = try await fetchChunk(page: nextPage, size: infiniteChunkSize)
            page = nextPage
            books.append(contentsOf: result.items)
            total = result.total
            errorText = nil
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "読み込みに失敗しました"
        }
    }

    func unlock(password: String) async {
        do {
            let token = try await client.unlock(libraryUUID: libraryUUID, password: password)
            libraryToken = token
            errorText = nil
            await reload()
        } catch RemoteClientError.forbidden {
            errorText = "パスワードが違います"
        } catch let e as RemoteClientError {
            errorText = Self.message(for: e)
        } catch {
            errorText = "解錠に失敗しました"
        }
    }

    /// 表紙バイト列を取得する（LRU キャッシュ経由）。失敗時は nil。
    func cover(bookID: Int) async -> Data? {
        // actor 境界を越える fetch クロージャが MainActor 隔離の self を捕捉しないよう、
        // 必要な値（Sendable）をローカルにコピーしてから渡す。
        let client = self.client
        let uuid = self.libraryUUID
        let token = self.libraryToken
        do {
            return try await coverCache.data(
                for: .init(libraryUUID: uuid, bookID: bookID, maxWidth: 300)
            ) {
                try await client.coverData(
                    libraryUUID: uuid, bookID: bookID, maxw: 300, libraryToken: token)
            }
        } catch {
            return nil
        }
    }

    // MARK: - Viewer

    /// リモート本を内蔵ビューワで開く。BookContent は RemoteBookContent。
    func openViewer(book: BookListItemDTO) {
        let content = RemoteBookContent(
            client: client,
            libraryUUID: libraryUUID,
            bookID: book.id,
            libraryToken: libraryToken,
            maxWidth: 1600
        )
        let row = Self.makeBookRow(from: book)
        Task { @MainActor in
            let pageCount: Int
            do {
                pageCount = try await content.pageCount
            } catch {
                self.errorText = "本を開けませんでした"
                return
            }
            guard pageCount > 0 else {
                self.errorText = "本を開けませんでした（0ページ）"
                return
            }
            // リモートでは per-book の永続見開き状態を持たないため、
            // グローバル既定（spreadByDefault）で開く。lastPage はサーバの値を尊重。
            let initialState = ResolvedViewerState(
                spreadEnabled: ViewerSettings.shared.spreadByDefault,
                coverOffset: true,
                lastPage: max(0, book.lastPage ?? 0),
                overrides: [:]
            )
            let options = ViewerOptions(
                pageDirection: row.pageDirection ?? ViewerSettings.shared.pageDirection,
                endOfBookBehavior: ViewerSettings.shared.endOfBookBehavior
            )
            let controller = ViewerWindowController(
                content: content,
                book: row,
                pageCount: pageCount,
                options: options,
                initialState: initialState,
                // リモートでは巻送り未対応（同一シリーズ解決はサーバ側に未実装）。
                loadNextVolume: { _ in nil },
                loadPrevVolume: { _ in nil },
                // 進捗をリモートサーバへ POST する（ローカル DB 書き込みの代替）。
                persistState: { [weak self] (b, lastPage, _, _) in
                    guard let self else { return }
                    Task {
                        try? await self.client.postProgress(
                            libraryUUID: self.libraryUUID, bookID: b.id,
                            page: lastPage, libraryToken: self.libraryToken)
                    }
                },
                // ページレイアウト override はリモートでは永続化しない（no-op）。
                persistPageOverride: { _, _, _ in },
                onClose: { [weak self] in self?.viewerController = nil }
            )
            self.viewerController = controller
            controller.present()
        }
    }

    /// BookListItemDTO から ViewerWindowController が必要とする最小限の BookRow を合成する。
    /// path は nil（リモートなので実ファイル参照は無い）だが、ViewerWindowController は
    /// content（RemoteBookContent）経由で読むため path には依存しない。
    private static func makeBookRow(from dto: BookListItemDTO) -> BookRow {
        BookRow(
            id: dto.id,
            title: dto.title,
            author: dto.author,
            genre: nil,
            path: nil,
            dateAdded: dto.dateAdded,
            playDate: dto.lastReadAt,
            bookType: dto.bookType,
            fileType: 0,
            pages: dto.pages,
            rating: dto.rating,
            unseen: dto.unseen,
            keywordA: nil,
            keywordB: nil,
            keywordC: nil,
            neta: nil,
            series: dto.series,
            volume: dto.volume
        )
    }

    // MARK: - Error messages

    static func message(for error: RemoteClientError) -> String {
        switch error {
        case .offline: return "サーバに接続できません（ネットワーク/アドレスを確認）"
        case .timeout: return "接続がタイムアウトしました"
        case .unauthorized: return "トークンが無効です"
        case .forbidden: return "アクセスが拒否されました"
        case .notFound: return "見つかりませんでした"
        case .server(let code): return "サーバエラー（\(code)）"
        case .decoding: return "応答の解析に失敗しました"
        case .badResponse: return "不正な応答を受信しました"
        }
    }
}
