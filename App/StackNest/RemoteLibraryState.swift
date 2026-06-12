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

    var books: [BookListItemDTO] = []
    var total = 0
    var page = 1
    var per = 100
    var query = ""
    var sortKey = "title"
    var ascending = true
    var isGrid = false
    var selection: Int? = nil
    var errorText: String? = nil

    let coverCache = RemoteCoverCache()

    /// ビューワを 1 ウィンドウだけ保持する（ローカル AppState.viewerController と同じ方針）。
    private var viewerController: ViewerWindowController?

    init(client: RemoteLibraryClient, libraryUUID: String, libraryName: String, locked: Bool, libraryToken: String? = nil) {
        self.client = client
        self.libraryUUID = libraryUUID
        self.libraryName = libraryName
        self.locked = locked
        self.libraryToken = libraryToken
    }

    var pageCountTotalPages: Int { max(1, Int(ceil(Double(total) / Double(per)))) }

    // MARK: - Loading

    func load() async {
        do {
            let result = try await client.fetchBooks(
                libraryUUID: libraryUUID,
                query: query.isEmpty ? nil : query,
                sort: sortKey,
                ascending: ascending,
                page: page,
                per: per,
                libraryToken: libraryToken
            )
            books = result.items
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
            await load()
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
