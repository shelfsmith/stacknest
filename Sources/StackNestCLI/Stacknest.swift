// SPDX-License-Identifier: MIT
import Foundation
import ArgumentParser
import LibraryServerAPI
import StackroomFormat
import StackNestL10n

// MARK: - Entry Point

@main
struct Stacknest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stacknest-cli",
        abstract: L10n.text("StackNest ライブラリ操作 CLI"),
        subcommands: [Libraries.self, FinderTagsCmd.self, List.self, Add.self, Rm.self, Set.self,
                      Detail.self, Facets.self, Shelves.self, Me.self,
                      Shelf.self, Watch.self, Lock.self, ImportConfigCmd.self,
                      ImportConfigGlobal.self, Relink.self, Dedup.self, Unlock.self,
                      Grant.self, Stamp.self, StampDefinitions.self, Label.self,
                      Integrity.self, Library.self, RenameFiles.self]
    )
}

// MARK: - 共通オプション

struct CommonOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp(L10n.text("StackNest サーバの URL（例: http://127.0.0.1:8765）")))
    var url: String?

    @Option(name: .long, help: ArgumentHelp(L10n.text("アクセストークン")))
    var token: String?

    @Option(name: [.customShort("L"), .long], help: ArgumentHelp(L10n.text("ライブラリ名または UUID")))
    var library: String?

    @Flag(name: .long, help: ArgumentHelp(L10n.text("JSON 形式で出力する")))
    var json: Bool = false
}

// MARK: - エラーマッピング

extension ParsableCommand {
    /// APIError を親切な文言＋終了コード 2 に統一する（認証/接続/サーバエラーは「致命」= 2）。
    /// ExitCode（add の一部失敗=1 等）は APIError でないのでそのまま伝播する。
    func mappingAPIErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as APIError {
            let code: Int32
            switch e {
            case .http(let s) where s == 403:
                fputs(L10n.text("エラー: アクセスが拒否されました（HTTP 403）。ロック庫の場合はライブラリトークン（env STACKNEST_LIBRARY_TOKEN）が失効している可能性があります。unlock で再取得してください。\n"), stderr)
                code = 3
            case .http(let s) where s == 401:
                fputs(L10n.text("エラー: 認証に失敗しました（HTTP 401）。トークンを確認してください（設定 ▸ ローカルアクセス ▸ 再生成、または --token で指定）。\n"), stderr)
                code = 2
            case .notFound:
                fputs(L10n.text("エラー: 対象が見つかりません（HTTP 404）。\n"), stderr)
                code = 2
            case .http(let s):
                fputs(L10n.format("エラー: サーバが HTTP %d を返しました。\n", s), stderr)
                code = 2
            case .network:
                fputs(L10n.text("エラー: サーバに接続できません。\nStackNest を起動し「ローカルアクセスを許可」が ON か確認してください（または --url / --token）。\n"), stderr)
                code = 2
            case .decode:
                fputs(L10n.text("エラー: サーバ応答を解釈できませんでした。\n"), stderr)
                code = 2
            }
            throw ExitCode(code)
        }
    }
}

// MARK: - 接続解決ヘルパ

extension ParsableCommand {
    /// CommonOptions から接続先を解決する。nil なら stderr に案内してコード 2 で throw。
    func resolveEndpoint(common: CommonOptions) throws -> ResolvedEndpoint {
        let env = ProcessInfo.processInfo.environment
        guard let ep = EndpointResolver.resolve(
            urlArg: common.url,
            tokenArg: common.token,
            env: env,
            defaultsPort: AppDefaults.localPort(),
            defaultsToken: AppDefaults.localToken()
        ) else {
            fputs(L10n.text("エラー: 接続先を解決できませんでした。\nStackNest を起動し「ローカルアクセスを許可」が ON か確認してください。\n--url / --token で明示指定することもできます。\n"), stderr)
            throw ExitCode(2)
        }
        return ep
    }
}

// MARK: - /libraries エンドポイント解決

extension ParsableCommand {
    /// --library 引数を使って LibraryDTO を解決する。複数ヒットはエラー。
    func resolveLibrary(client: APIClient, libArg: String?) throws -> LibraryDTO {
        let data = try client.libraries()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let libs = try decoder.decode([LibraryDTO].self, from: data)
        if libs.isEmpty {
            fputs(L10n.text("エラー: 開いているライブラリがありません。StackNest でライブラリを開いてください。\n"), stderr)
            throw ExitCode(2)
        }
        guard let arg = libArg else {
            if libs.count == 1 { return libs[0] }
            fputs(L10n.text("エラー: ライブラリが複数あります。--library で指定してください:\n"), stderr)
            for lib in libs { fputs("  \(lib.id)  \(lib.name)\n", stderr) }
            throw ExitCode(2)
        }
        let matches = libs.filter { $0.id == arg || $0.name == arg }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            fputs(L10n.format("エラー: 名前「%@」が複数のライブラリに一致します。UUID で指定してください:\n", arg), stderr)
            for lib in matches { fputs("  \(lib.id)  \(lib.name)\n", stderr) }
            throw ExitCode(2)
        }
        fputs(L10n.format("エラー: ライブラリ「%@」が見つかりません。\n", arg), stderr)
        throw ExitCode(2)
    }
}

// MARK: - libraries

struct Libraries: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "libraries",
        abstract: L10n.text("開いているライブラリ一覧を表示する")
    )
    @OptionGroup var common: CommonOptions

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let data = try client.libraries()
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let libs = try decoder.decode([LibraryDTO].self, from: data)
            for lib in libs {
                let count = L10n.plural("%d 冊", count: lib.bookCount, lib.bookCount)
                let lockSuffix = lib.locked ? L10n.text(" [ロック]") : ""
                print("\(lib.id)  \(lib.name)  (\(count))\(lockSuffix)")
            }
        }
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: L10n.text("ライブラリの書籍一覧を表示する（検索/フィルタ/ブラウズ/ソート対応）")
    )
    @OptionGroup var common: CommonOptions
    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.text("検索キーワード")))
    var query: String?
    @Option(name: .shortAndLong, help: ArgumentHelp(L10n.text("取得件数（既定 100・最大 500）")))
    var limit: Int?
    @Option(name: .long, help: ArgumentHelp(L10n.text("ソートキー（例: title, dateAdded）")))
    var sort: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("並び順 (asc/desc)")))
    var order: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("サイドバースコープ（例: all, recent, shelf）")))
    var scope: String?
    @Option(name: [.customLong("scope-id")], help: ArgumentHelp(L10n.text("スコープ対象 ID（棚 ID 等）")))
    var scopeId: Int64?
    @Option(name: [.customLong("recent-days")], help: ArgumentHelp(L10n.text("scope=recent の日数")))
    var recentDays: Int?
    @Option(name: .long, help: ArgumentHelp(L10n.text("追加フィールドをカンマ区切りで要求（genre,neta,keywordA,...）")))
    var fields: String?
    @Option(name: [.customLong("filter-json")], help: ArgumentHelp(L10n.text("FilterState の JSON")))
    var filterJSON: String?
    @Option(name: [.customLong("browse-json")], help: ArgumentHelp(L10n.text("ブラウズ条件 JSON（[{\"column\":...,\"value\":...}]）")))
    var browseJSON: String?

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let data = try client.listBooks(
                uuid: lib.id, query: query, limit: limit,
                sort: sort, order: order, scope: scope, scopeId: scopeId,
                recentDays: recentDays, fields: fields,
                filterJSON: filterJSON, browseJSON: browseJSON)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let page = try decoder.decode(BookPageDTO.self, from: data)
            for book in page.items {
                print("\(book.id)\t\(book.title)\t\(book.author ?? "")")
            }
            print(L10n.format("--- 表示 %d / 計 %d 冊 ---", page.items.count, page.total))
        }
    }
}

// MARK: - add

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: L10n.text("書籍ファイルをライブラリに追加する")
    )
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("追加するファイルまたはフォルダのパス（複数可）")))
    var paths: [String]
    @Option(name: .long, help: ArgumentHelp(L10n.text("取り込みプリセット ID")))
    var preset: String?

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            // I-1: CLI の CWD を基準に相対パスを絶対パスに変換する（サーバの CWD は無関係）
            let absolutePaths = paths.map { path in
                URL(fileURLWithPath: path).standardizedFileURL.path
            }
            let req = AddBooksRequestDTO(paths: absolutePaths, presetID: preset)
            let reply = try client.add(uuid: lib.id, req: req)
            if common.json {
                let encoder = JSONEncoder()
                let data = try encoder.encode(reply)
                print(String(data: data, encoding: .utf8) ?? "")
            } else {
                let ids = reply.addedIDs.map(String.init).joined(separator: ",")
                print(L10n.plural("追加: %d 冊 (IDs: %@)", count: reply.addedIDs.count, reply.addedIDs.count, ids))
                if !reply.alreadyPresent.isEmpty {
                    print(L10n.format("既存: %@", reply.alreadyPresent.joined(separator: ", ")))
                }
                if !reply.failed.isEmpty {
                    fputs(L10n.format("失敗: %@\n", reply.failed.joined(separator: ", ")), stderr)
                }
            }
            if !reply.failed.isEmpty { throw ExitCode(1) }
        }
    }
}

// MARK: - rm

struct Rm: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: L10n.text("書籍をライブラリから削除する")
    )
    @OptionGroup var common: CommonOptions
    // I-2: 複数 ID 対応
    @Argument(help: ArgumentHelp(L10n.text("削除する書籍の ID（複数可）")))
    var ids: [Int]
    @Flag(name: .long, help: ArgumentHelp(L10n.text("ゴミ箱に移動する（既定: DB から削除のみ）")))
    var trash: Bool = false

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)

            var failedIDs: [Int] = []
            for id in ids {
                do {
                    try client.remove(uuid: lib.id, id: id, trash: trash)
                    if !common.json {
                        print(L10n.format("削除しました (id=%d)", id))
                    }
                } catch {
                    fputs(L10n.format("エラー (id=%d): %@\n", id, "\(error)"), stderr)
                    failedIDs.append(id)
                }
            }
            if !failedIDs.isEmpty {
                throw ExitCode(1)
            }
        }
    }
}

// MARK: - set

struct Set: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: L10n.text("書籍のメタデータを更新する")
    )
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("対象書籍の ID")))
    var id: Int
    // I-3: spec §3.4 の全メタ文字列/数値フィールドを追加（unseen は除外）
    @Option(name: .long, help: ArgumentHelp(L10n.text("タイトル")))
    var title: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("著者")))
    var author: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("シリーズ名")))
    var series: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("巻番号")))
    var volume: Int?
    @Option(name: .long, help: ArgumentHelp(L10n.text("ジャンル")))
    var genre: String?
    @Option(name: [.customLong("keyword-a")], help: ArgumentHelp(L10n.text("キーワード A")))
    var keywordA: String?
    @Option(name: [.customLong("keyword-b")], help: ArgumentHelp(L10n.text("キーワード B")))
    var keywordB: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("メモ")))
    var memo: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("ネタ")))
    var neta: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("レーティング (0-5)")))
    var rating: Int?
    @Option(name: .long, help: ArgumentHelp(L10n.text("未読フラグ (true/false)")))
    var unseen: Bool?
    @Option(name: [.customLong("book-type")], help: ArgumentHelp(L10n.text("本の種類 (整数)")))
    var bookType: Int?
    @Option(name: .long, help: ArgumentHelp(L10n.text("読み方向 (ltr/rtl/clear)")))
    var direction: String?

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            // volume: CLI は Int? で受け取り、BookPatchDTO は Double? なので変換
            let volumeDouble: Double? = volume.map { Double($0) }
            var patch = BookPatchDTO(
                title: title,
                author: author,
                genre: genre,
                neta: neta,
                memo: memo,
                keywordA: keywordA,
                keywordB: keywordB,
                rating: rating,
                series: series,
                volume: volumeDouble
            )
            if let unseen { patch.unseen = unseen }
            if let bookType { patch.bookType = bookType }
            if let direction {
                guard ["ltr", "rtl", "clear"].contains(direction) else {
                    throw ValidationError(L10n.text("--direction は ltr / rtl / clear のいずれかを指定してください"))
                }
                if direction == "clear" { patch.clearPageDirection = true } else { patch.pageDirection = direction }
            }
            try client.patch(uuid: lib.id, id: id, body: patch)
            if !common.json {
                print(L10n.format("更新しました (id=%d)", id))
            }
        }
    }
}

// MARK: - detail

struct Detail: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detail",
        abstract: L10n.text("書籍の詳細情報を表示する")
    )
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("書籍 ID")))
    var id: Int

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let data = try client.detail(uuid: lib.id, id: id)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let book = try decoder.decode(BookDetailDTO.self, from: data)
            print("id:       \(book.id)")
            print("title:    \(book.title)")
            if let v = book.author   { print("author:   \(v)") }
            if let v = book.series   { print("series:   \(v)") }
            if let v = book.volume   { print("volume:   \(v)") }
            if let v = book.genre    { print("genre:    \(v)") }
            if let v = book.neta     { print("neta:     \(v)") }
            if let v = book.memo     { print("memo:     \(v)") }
            if let v = book.keywordA { print("keywordA: \(v)") }
            if let v = book.keywordB { print("keywordB: \(v)") }
            print("rating:   \(book.rating)")
            print("unseen:   \(book.unseen)")
            print("bookType: \(book.bookType)")
            if let v = book.pages    { print("pages:    \(v)") }
            if let v = book.lastPage { print("lastPage: \(v)") }
            if let v = book.pageDirection { print("direction:\(v)") }
        }
    }
}

// MARK: - facets

struct Facets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "facets",
        abstract: L10n.text("指定フィールドの distinct 値一覧を表示する")
    )
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("フィールド名（例: author, genre, series）")))
    var field: String

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let data = try client.facets(uuid: lib.id, field: field)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let decoder = JSONDecoder()
            if let values = try? decoder.decode([String].self, from: data) {
                for v in values { print(v) }
                print(L10n.plural("--- %d 件 ---", count: values.count, values.count))
            } else {
                // デコード失敗時は生データを表示
                print(String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}

// MARK: - shelves

struct Shelves: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shelves",
        abstract: L10n.text("ライブラリの棚一覧を表示する")
    )
    @OptionGroup var common: CommonOptions

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let data = try client.shelves(uuid: lib.id)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let decoder = JSONDecoder()
            let shelfList = try decoder.decode([ShelfDTO].self, from: data)
            for shelf in shelfList { print(Self.humanLine(shelf)) }
        }
    }

    /// 人向けの 1 行。お気に入り棚は画面と同じく訳す（`--json` は保存値のまま）。
    static func humanLine(_ shelf: ShelfDTO) -> String {
        let kind = shelf.isSmart ? "smart" : "user"
        return "\(shelf.id)\t\(L10nSeed.shelfTitle(shelf.title, kind: shelf.kind))\t[\(kind)]"
    }
}

// MARK: - me

struct Me: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "me",
        abstract: L10n.text("現在のトークンの権限情報を表示する")
    )
    @OptionGroup var common: CommonOptions

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let data = try client.me()
            if common.json { print(String(data: data, encoding: .utf8) ?? ""); return }
            let me = try JSONDecoder().decode(MeReply.self, from: data)
            let scopeStr: String
            switch me.scope {
            case .all: scopeStr = L10n.text("all（全ライブラリ）")
            case .libraries(let ids): scopeStr = L10n.plural("%d ライブラリ: %@", count: ids.count, ids.count, ids.joined(separator: ", "))
            }
            print("role: \(me.role.rawValue)\ntier: \(me.tier.rawValue)\nscope: \(scopeStr)")
        }
    }
}

// MARK: - shelf グループ

struct Shelf: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shelf", abstract: L10n.text("棚（スマート/手動）を管理する"),
        subcommands: [ShelfCreate.self, ShelfRm.self, ShelfRename.self,
                      ShelfConditionsGet.self, ShelfConditionsSet.self,
                      ShelfAddBooks.self, ShelfRemoveBooks.self])
}
struct ShelfCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: L10n.text("棚を作成する"))
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: ArgumentHelp(L10n.text("棚名"))) var title: String
    @Flag(name: .long, help: ArgumentHelp(L10n.text("スマート棚にする"))) var smart: Bool = false
    @Option(name: [.customLong("conditions-json")], help: ArgumentHelp(L10n.text("スマート棚条件 JSON (SmartShelfConditions)"))) var conditionsJSON: String?
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            var conditions: SmartShelfConditions?
            if let conditionsJSON {
                conditions = try JSONDecoder().decode(SmartShelfConditions.self, from: Data(conditionsJSON.utf8))
            }
            if smart && conditions == nil { throw ValidationError(L10n.text("--smart 時は --conditions-json が必要です")) }
            let body = ShelfCreateRequest(title: title, isSmart: smart, conditions: conditions)
            let data = try client.shelfCreate(uuid: lib.id, body: body)
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }
}
struct ShelfRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: L10n.text("棚を削除する"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("棚 ID"))) var id: Int64
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            try client.shelfDelete(uuid: lib.id, id: id)
            print(L10n.format("削除しました (shelf=%lld)", id))
        }
    }
}
struct ShelfRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: L10n.text("棚を改名する"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("棚 ID"))) var id: Int64
    @Option(name: .long, help: ArgumentHelp(L10n.text("新しい棚名"))) var title: String
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let data = try client.shelfPatch(uuid: lib.id, id: id, body: ShelfUpdateRequest(title: title))
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }
}
struct ShelfConditionsGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "conditions-get", abstract: L10n.text("スマート棚の条件を表示する"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("棚 ID"))) var id: Int64
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            print(String(data: try client.shelfConditionsGet(uuid: lib.id, id: id), encoding: .utf8) ?? "")
        }
    }
}
struct ShelfConditionsSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "conditions-set", abstract: L10n.text("スマート棚の条件を更新する"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("棚 ID"))) var id: Int64
    @Option(name: [.customLong("conditions-json")], help: ArgumentHelp(L10n.text("条件 JSON (SmartShelfConditions)"))) var conditionsJSON: String
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            // 妥当性のためデコードしてから再エンコード（不正 JSON は早期に弾く）
            let cond = try JSONDecoder().decode(SmartShelfConditions.self, from: Data(conditionsJSON.utf8))
            let body = try JSONEncoder().encode(cond)
            print(String(data: try client.shelfConditionsPut(uuid: lib.id, id: id, conditionsJSON: body), encoding: .utf8) ?? "")
        }
    }
}
struct ShelfAddBooks: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-books", abstract: L10n.text("手動棚に本を追加する"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("棚 ID"))) var id: Int64
    @Argument(help: ArgumentHelp(L10n.text("追加する書籍 ID（複数可）"))) var bookIDs: [Int]
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            try client.shelfBooksAdd(uuid: lib.id, id: id, bookIDs: bookIDs)
            print(L10n.plural("追加しました (shelf=%lld, books=%d)", count: bookIDs.count, id, bookIDs.count))
        }
    }
}
struct ShelfRemoveBooks: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-books", abstract: L10n.text("手動棚から本を除去する"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("棚 ID"))) var id: Int64
    @Argument(help: ArgumentHelp(L10n.text("除去する書籍 ID（複数可）"))) var bookIDs: [Int]
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            try client.shelfBooksRemove(uuid: lib.id, id: id, bookIDs: bookIDs)
            print(L10n.plural("除去しました (shelf=%lld, books=%d)", count: bookIDs.count, id, bookIDs.count))
        }
    }
}

// MARK: - watch グループ

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: L10n.text("監視フォルダ設定"), subcommands: [WatchGet.self, WatchSet.self])
}
struct WatchGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.watchGet(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}
struct WatchSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: L10n.text("監視設定を全置換する"))
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("config-json")], help: ArgumentHelp(L10n.text("WatchConfigDTO の JSON"))) var configJSON: String
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        let cfg = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(configJSON.utf8))
        let body = try JSONEncoder().encode(cfg)
        print(String(data: try client.watchPut(uuid: lib.id, configJSON: body), encoding: .utf8) ?? "")
    } }
}

// MARK: - lock グループ

struct Lock: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lock", abstract: L10n.text("庫ロック (admin)"), subcommands: [LockSet.self, LockClear.self])
}
struct LockSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: L10n.text("パスワードロックを設定・変更する（既存ロックの変更には現在のパスワードが必須）"))
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: ArgumentHelp(L10n.text("新しいパスワード（argv に残るため自動化では --password-stdin 推奨）"))) var password: String?
    @Flag(name: [.customLong("password-stdin")], help: ArgumentHelp(L10n.text("新しいパスワードを標準入力から読む（argv 非露出）"))) var passwordStdin: Bool = false
    @Option(name: .long, help: ArgumentHelp(L10n.text("現在のパスワード（既存ロックの変更時のみ必須。新規設定時は不要。argv に残るため自動化では --current-password-stdin 推奨）")))
    var currentPassword: String?
    @Flag(name: [.customLong("current-password-stdin")],
          help: ArgumentHelp(L10n.text("現在のパスワードを標準入力から読む（argv 非露出。--password-stdin と併用時は「現在のパスワード\\n新しいパスワード」の2行として読む）")))
    var currentPasswordStdin: Bool = false
    func run() throws { try mappingAPIErrors {
        var cur = currentPassword
        let pw: String
        if currentPasswordStdin && passwordStdin {
            // G27a Task6: 両方を argv に出さずに渡すため、1 行目=現在のパスワード / 2 行目=新しいパスワード
            // として標準入力から読む（既存の unlock/lock set の「stdin=パスワード全体」を単純延長）。
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ValidationError(L10n.text("--current-password-stdin と --password-stdin を併用する場合、標準入力に「現在のパスワード\\n新しいパスワード」の2行を渡してください"))
            }
            cur = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            pw = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            if currentPasswordStdin {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                cur = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if passwordStdin {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                pw = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let password {
                pw = password
            } else {
                throw ValidationError(L10n.text("--password または --password-stdin を指定してください"))
            }
        }
        guard !pw.isEmpty else { throw ValidationError(L10n.text("パスワードが空です")) }
        if let c = cur, c.isEmpty { cur = nil }
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        try client.lockSet(uuid: lib.id, password: pw, currentPassword: cur); print(L10n.text("ロックを設定しました"))
    } }
}
struct LockClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: L10n.text("ロックを解除する（既存ロックがある場合は現在のパスワードが必須）"))
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: ArgumentHelp(L10n.text("現在のパスワード（既存ロックがある場合は必須。argv に残るため自動化では --current-password-stdin 推奨）")))
    var currentPassword: String?
    @Flag(name: [.customLong("current-password-stdin")], help: ArgumentHelp(L10n.text("現在のパスワードを標準入力から読む（argv 非露出）")))
    var currentPasswordStdin: Bool = false
    func run() throws { try mappingAPIErrors {
        var cur = currentPassword
        if currentPasswordStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            cur = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let c = cur, c.isEmpty { cur = nil }
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        try client.lockClear(uuid: lib.id, currentPassword: cur); print(L10n.text("ロックを解除しました"))
    } }
}

// MARK: - import-config グループ（per-library）

struct ImportConfigCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-config", abstract: L10n.text("取り込み設定 (per-library override)"), subcommands: [ImportGet.self, ImportSet.self])
}
struct ImportGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.importGet(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}
struct ImportSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: L10n.text("override を設定する（指定分のみ）"))
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("auto-classify")], help: ArgumentHelp(L10n.text("自動分類 (true/false)"))) var autoClassify: Bool?
    @Option(name: .long, help: ArgumentHelp(L10n.text("厚い本判定閾値"))) var thick: Int?
    // G54-S4 Task 7: 未指定 (nil) は override 削除（= グローバル既定に委譲）。autoClassify と同じ形。
    @Option(name: [.customLong("prefer-epub-title")], help: ArgumentHelp(L10n.text("EPUB の題名を使う (true/false)"))) var preferEPUBTitle: Bool?
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        let body = ImportConfigDTO(autoClassifyEnabled: autoClassify, thickBookThreshold: thick, preferEPUBTitle: preferEPUBTitle)
        print(String(data: try client.importPut(uuid: lib.id, body: body), encoding: .utf8) ?? "")
    } }
}

// MARK: - import-config-global グループ（admin）

struct ImportConfigGlobal: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-config-global", abstract: L10n.text("取り込みグローバル既定 (admin)"), subcommands: [ImportGlobalGet.self, ImportGlobalSet.self])
}
struct ImportGlobalGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        print(String(data: try client.importGlobalGet(), encoding: .utf8) ?? "")
    } }
}
struct ImportGlobalSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set")
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("auto-classify")], help: ArgumentHelp(L10n.text("自動分類 (true/false)"))) var autoClassify: Bool
    @Option(name: .long, help: ArgumentHelp(L10n.text("厚い本判定閾値"))) var thick: Int
    // G54-S4 Task 7: グローバルは常に全項目を指定する（サーバ canonical・autoClassify と同じ形）。
    @Option(name: [.customLong("prefer-epub-title")], help: ArgumentHelp(L10n.text("EPUB の題名を使う (true/false)"))) var preferEPUBTitle: Bool
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let body = GlobalImportConfigDTO(autoClassifyEnabled: autoClassify, thickBookThreshold: thick, preferEPUBTitle: preferEPUBTitle)
        print(String(data: try client.importGlobalPut(body: body), encoding: .utf8) ?? "")
    } }
}

// MARK: - unlock

struct Unlock: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: L10n.text("ロック庫を解錠し短命ライブラリトークンを取得する（以後 env STACKNEST_LIBRARY_TOKEN に設定して使う）"))
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: ArgumentHelp(L10n.text("パスワード（argv に残るため自動化では --password-stdin 推奨）"))) var password: String?
    @Flag(name: [.customLong("password-stdin")], help: ArgumentHelp(L10n.text("パスワードを標準入力から読む（argv 非露出）"))) var passwordStdin: Bool = false
    func run() throws { try mappingAPIErrors {
        let pw: String
        if passwordStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            pw = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let password {
            pw = password
        } else {
            throw ValidationError(L10n.text("--password または --password-stdin を指定してください"))
        }
        guard !pw.isEmpty else { throw ValidationError(L10n.text("パスワードが空です")) }
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        let data = try client.unlock(uuid: lib.id, password: pw)
        if common.json { print(String(data: data, encoding: .utf8) ?? ""); return }
        let reply = try JSONDecoder().decode(UnlockReply.self, from: data)
        // トークンのみ stdout（`STACKNEST_LIBRARY_TOKEN=$(... unlock ...)` で受けられるよう余計な装飾を出さない）
        print(reply.libraryToken)
    } }
}

// MARK: - relink / dedup

struct Relink: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "relink", abstract: L10n.text("本のパスを再リンクする"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("書籍 ID"))) var id: Int
    @Option(name: [.customLong("new-path")], help: ArgumentHelp(L10n.text("新しいパス"))) var newPath: String
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        try client.relink(uuid: lib.id, id: id, newPath: newPath); print(L10n.format("再リンクしました (id=%d)", id))
    } }
}
struct Dedup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dedup", abstract: L10n.text("重複スキャンを実行する"))
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.dedup(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}

// MARK: - integrity グループ（整合性検査・G27a）

struct Integrity: ParsableCommand {
    // fix round 4 (Minor, whole-branch review): GUI 側は Phase G29 Task 4 で
    // 「蔵書ファイルの破損チェック」に改名済み（2026-08-08 smoke フィードバックでさらに
    // 「ファイルの破損チェック」へ短縮）。CLI の abstract だけ旧語彙「整合性」が残っていた。
    static let configuration = CommandConfiguration(
        commandName: "integrity", abstract: L10n.text("ファイルの破損を検査する"),
        subcommands: [IntegrityScanCmd.self, IntegrityStatusCmd.self, IntegrityListCmd.self,
                      IntegrityFullScanCmd.self, IntegrityJobStatusCmd.self, IntegrityCancelCmd.self])
}

struct IntegrityScanCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan", abstract: L10n.text("pages 未取得の本を開いて分類する（簡易チェック）"))
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.integrityScan(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}

struct IntegrityStatusCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: L10n.text("検査済/未検査/破損/劣化の件数を表示する"))
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.integritySummary(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}

struct IntegrityListCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: L10n.text("指定した状態の本を一覧する"))
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: ArgumentHelp(L10n.text("ok / damaged / empty / missing / unsupported（既定: damaged）")))
    var status: String = "damaged"
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.integrityList(uuid: lib.id, status: status), encoding: .utf8) ?? "")
    } }
}

// MARK: - full-scan（G27b Task5・非同期ジョブ）
//
// ★重要: 実測 4.464 秒/冊・22,880 冊規模で約 31 時間かかる。このコマンドは **完走を待たない**
// （--wait 相当のオプションは意図的に用意しない ―― 用意すれば確実にタイムアウトする）。
// 「投げて 202 を確認して抜ける」だけを行い、進捗は job-status、中断は cancel で行う。

/// --mode に渡せる値（サーバの unchecked/all/damaged と 1:1）。
private let fullScanValidModes = ["unchecked", "all", "damaged"]

struct IntegrityFullScanCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "full-scan",
        abstract: L10n.text("全冊 CRC 検証を非同期ジョブとして開始する（数千冊規模で数十時間かかりうる・完走は待たない）"))
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: ArgumentHelp(L10n.text("unchecked（既定・未検査のみ）/ all（全件再検査）/ damaged（前回破損のみ再検査）")))
    var mode: String = "unchecked"

    func run() throws {
        guard fullScanValidModes.contains(mode) else {
            fputs(L10n.format("エラー: --mode は unchecked/all/damaged のいずれかです（指定値: %@）\n", mode), stderr)
            throw ExitCode(2)
        }
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            do {
                _ = try client.startFullScan(uuid: lib.id, mode: mode)
            } catch APIError.http(409) {
                print(L10n.text("既に実行中のメンテナンスジョブがあります。`stacknest-cli integrity job-status` で状況を確認してください。"))
                return
            }
            print(L10n.format("フルスキャン（mode=%@）を開始しました。バックグラウンドジョブとして動作します。\n実測値: 約 4.5 秒/冊 ―― 蔵書規模によっては数十時間（例: 22,880 冊で約 31 時間）かかります。\nこのコマンドは完走を待たずに終了しました。進捗・中断は以下で行ってください:\n  進捗確認: stacknest-cli integrity job-status\n  中断:     stacknest-cli integrity cancel", mode))
        }
    }
}

struct IntegrityJobStatusCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "job-status",
        abstract: L10n.text("実行中のメンテナンスジョブ（full-scan 含む）の進捗を表示する"))
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.maintenanceStatus(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}

struct IntegrityCancelCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: L10n.text("実行中のメンテナンスジョブ（full-scan 含む）を中断する（実行中ジョブが無ければ no-op）"))
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        try client.maintenanceCancel(uuid: lib.id)
        print(L10n.text("中断リクエストを送信しました。"))
    } }
}

// MARK: - library グループ（ローカル制御専用・G27b Task7）
//
// 任意パスを開ける API は実質的なファイルシステム探索になるため、サーバ側は 127.0.0.1 の
// ローカル制御にのみこのルートを持つ（共有サーバへ --url で繋いだ場合は 404 になる）。

struct Library: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "library", abstract: L10n.text("ライブラリを開閉する（ローカル制御専用・共有サーバでは使えない）"),
        subcommands: [LibraryOpen.self, LibraryClose.self])
}
struct LibraryOpen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: L10n.text("パスを指定してライブラリウィンドウを開く（既に開いていれば既存の UUID を返す）"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("開くライブラリバンドルの絶対パス"))) var path: String
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            // CLI の CWD を基準に相対パスを絶対パスへ変換する（add と同じ規約）。
            let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
            let data = try client.openLibrary(path: absolutePath)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let decoder = JSONDecoder()
            let reply = try decoder.decode(OpenLibraryReply.self, from: data)
            // uuid のみ出力（`STACKNEST_UUID=$(stacknest-cli library open ...)` のように受けられる）。
            print(reply.uuid)
        }
    }
}
struct LibraryClose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: L10n.text("UUID を指定してライブラリウィンドウを閉じる"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("閉じるライブラリの UUID（stacknest-cli libraries で確認）"))) var uuid: String
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            try client.closeLibrary(uuid: uuid)
            if !common.json {
                print(L10n.format("閉じました (uuid=%@)", uuid))
            }
        }
    }
}

// MARK: - grant グループ（admin）

/// --scope / --scope-libraries / --scope-json から GrantScope を解決する共通ヘルパ。
/// いずれも未指定なら nil（update では「変更しない」、create では呼び出し側が .all 既定にする）。
enum GrantScopeArg {
    static func resolve(scope: String?, scopeLibraries: String?, scopeJSON: String?) throws -> GrantScope? {
        let specified = [scope, scopeLibraries, scopeJSON].compactMap { $0 }
        if specified.count > 1 {
            throw ValidationError(L10n.text("--scope / --scope-libraries / --scope-json は同時指定できません"))
        }
        if let scopeJSON {
            return try JSONDecoder().decode(GrantScope.self, from: Data(scopeJSON.utf8))
        }
        if let scopeLibraries {
            let ids = scopeLibraries.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .libraries(ids)
        }
        if let scope {
            guard scope == "all" else { throw ValidationError(L10n.text("--scope は all のみ指定可能（個別指定は --scope-libraries）")) }
            return .all
        }
        return nil
    }
}

struct Grant: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grant", abstract: L10n.text("アクセスグラントを管理する (admin)"),
        subcommands: [GrantList.self, GrantCreate.self, GrantUpdate.self, GrantRm.self])
}
struct GrantList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: L10n.text("グラント一覧を表示する"))
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let data = try client.grantList()
        if common.json { print(String(data: data, encoding: .utf8) ?? ""); return }
        let grants = try JSONDecoder().decode([GrantDTO].self, from: data)
        for g in grants { print(Self.humanLine(g)) }
    } }

    /// 人向けの 1 行。既定ラベルは画面と同じく訳す（`--json` は保存値のまま）。
    static func humanLine(_ g: GrantDTO) -> String {
        let scopeStr: String
        switch g.scope {
        case .all: scopeStr = "all"
        case .libraries(let ids): scopeStr = ids.joined(separator: ",")
        }
        return "\(g.id)\t\(g.tier.rawValue)\t\(L10nSeed.grantLabel(g.label))\t[\(scopeStr)]"
    }
}
struct GrantCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: L10n.text("グラントを作成する（token を返す）"))
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: ArgumentHelp(L10n.text("ラベル"))) var label: String
    @Option(name: .long, help: ArgumentHelp(L10n.text("権限階層 (read/edit/admin)"))) var tier: String
    @Option(name: .long, help: ArgumentHelp(L10n.text("スコープ all（全ライブラリ）"))) var scope: String?
    @Option(name: [.customLong("scope-libraries")], help: ArgumentHelp(L10n.text("対象ライブラリ UUID をカンマ区切りで指定"))) var scopeLibraries: String?
    @Option(name: [.customLong("scope-json")], help: ArgumentHelp(L10n.text("GrantScope の JSON を直接指定"))) var scopeJSON: String?
    func run() throws { try mappingAPIErrors {
        guard let t = AccessTier(rawValue: tier) else { throw ValidationError(L10n.text("--tier は read / edit / admin のいずれか")) }
        let resolved = try GrantScopeArg.resolve(scope: scope, scopeLibraries: scopeLibraries, scopeJSON: scopeJSON)
        let body = GrantCreateRequest(label: label, tier: t, scope: resolved ?? .all)
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        print(String(data: try client.grantCreate(body: body), encoding: .utf8) ?? "")
    } }
}
struct GrantUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: L10n.text("グラントを更新する（指定分のみ）"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("グラント ID"))) var id: String
    @Option(name: .long, help: ArgumentHelp(L10n.text("ラベル"))) var label: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("権限階層 (read/edit/admin)"))) var tier: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("スコープ all"))) var scope: String?
    @Option(name: [.customLong("scope-libraries")], help: ArgumentHelp(L10n.text("対象ライブラリ UUID をカンマ区切り"))) var scopeLibraries: String?
    @Option(name: [.customLong("scope-json")], help: ArgumentHelp(L10n.text("GrantScope の JSON"))) var scopeJSON: String?
    func run() throws { try mappingAPIErrors {
        var t: AccessTier?
        if let tier {
            guard let parsed = AccessTier(rawValue: tier) else { throw ValidationError(L10n.text("--tier は read / edit / admin のいずれか")) }
            t = parsed
        }
        let resolved = try GrantScopeArg.resolve(scope: scope, scopeLibraries: scopeLibraries, scopeJSON: scopeJSON)
        let body = GrantUpdateRequest(label: label, tier: t, scope: resolved)
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        print(String(data: try client.grantUpdate(id: id, body: body), encoding: .utf8) ?? "")
    } }
}
struct GrantRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: L10n.text("グラントを削除する"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("グラント ID"))) var id: String
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        try client.grantDelete(id: id); print(L10n.format("削除しました (grant=%@)", id))
    } }
}

// MARK: - stamp（一括スタンプ適用・edit）

struct Stamp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stamp", abstract: L10n.text("複数の本に値を一括スタンプ（追記）/クリアする"))
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: ArgumentHelp(L10n.text("対象フィールド（例: genre, keyword_a）"))) var field: String
    @Option(name: .long, help: ArgumentHelp(L10n.text("追記する値（--clear と排他）"))) var value: String?
    @Flag(name: .long, help: ArgumentHelp(L10n.text("値をクリアする（--value と排他）"))) var clear: Bool = false
    @Argument(help: ArgumentHelp(L10n.text("対象書籍 ID（複数可）"))) var bookIDs: [Int]
    func run() throws { try mappingAPIErrors {
        if (value == nil) == (clear == false) {
            throw ValidationError(L10n.text("--value または --clear のいずれか一方を指定してください"))
        }
        guard !bookIDs.isEmpty else { throw ValidationError(L10n.text("対象書籍 ID を 1 件以上指定してください")) }
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        let body = StampApplyRequest(field: field, value: value, clear: clear ? true : nil, bookIDs: bookIDs)
        let data = try client.stampApply(uuid: lib.id, body: body)
        if common.json { print(String(data: data, encoding: .utf8) ?? ""); return }
        let reply = try JSONDecoder().decode(StampApplyReply.self, from: data)
        print(L10n.plural("更新: %d 冊", count: reply.updated, reply.updated))
    } }
}

// MARK: - stamp-definitions（スタンプ定義の取得/全置換・edit）

struct StampDefinitions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stamp-definitions", abstract: L10n.text("スタンプ定義を取得/更新する"),
        subcommands: [StampDefinitionsGet.self, StampDefinitionsSet.self])
}
struct StampDefinitionsGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.stampDefinitionsGet(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}
struct StampDefinitionsSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: L10n.text("スタンプ定義を全置換する"))
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("definitions-json")], help: ArgumentHelp(L10n.text("StampDefinitionsDTO の JSON"))) var definitionsJSON: String
    func run() throws { try mappingAPIErrors {
        // 妥当性のためデコードしてから再エンコード（不正 JSON は早期に弾く）
        let dto = try JSONDecoder().decode(StampDefinitionsDTO.self, from: Data(definitionsJSON.utf8))
        let body = try JSONEncoder().encode(dto)
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.stampDefinitionsPut(uuid: lib.id, json: body), encoding: .utf8) ?? "")
    } }
}

// MARK: - label（ラベルカスタマイズの取得/更新・edit）

struct Label: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label", abstract: L10n.text("ラベルカスタマイズを取得/更新する"),
        subcommands: [LabelGet.self, LabelSet.self])
}
struct LabelGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.labelGet(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}
struct LabelSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: L10n.text("ラベルカスタマイズを更新する"))
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("settings-json")], help: ArgumentHelp(L10n.text("LabelSettingsDTO の JSON ({customFieldLabels,customBookTypeLabels})"))) var settingsJSON: String
    func run() throws { try mappingAPIErrors {
        let dto = try JSONDecoder().decode(LabelSettingsDTO.self, from: Data(settingsJSON.utf8))
        let body = try JSONEncoder().encode(dto)
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.labelPut(uuid: lib.id, json: body), encoding: .utf8) ?? "")
    } }
}


// MARK: - finder-tags グループ（ローカル制御専用・admin）

/// Finder タグ同期を CLI/MCP から触るためのグループ。
///
/// **同期そのものは走らせない。**稼働中のアプリに「メニューの再照合」を押させ、
/// 終わるまで待って結果を受け取るだけ（spec §5「照合 1 本に集約」）。
/// だから庫がアプリで開いていないと 404 になる —— それが正しい。
/// ここで CLI が自前に同期を回すと、施錠ゲートも二重起動の抑止も通らない
/// 2 本目の経路ができてしまう。
struct FinderTagsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finder-tags",
        abstract: L10n.text("Finder タグ同期の状態確認と手動再照合（ローカル制御専用・共有サーバでは使えない）"),
        subcommands: [FinderTagsStatus.self, FinderTagsSet.self, FinderTagsResync.self])
}

struct FinderTagsStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: L10n.text("同期対象の項目・走行中か・施錠中かを表示する"))
    @OptionGroup var common: CommonOptions
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let data = try client.finderTagStatus(uuid: lib.id)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let reply = try JSONDecoder().decode(FinderTagSyncStatusReply.self, from: data)
            print(L10n.format("項目: %@", reply.field ?? L10n.text("（同期しない）")))
            print(L10n.format("走行中: %@", reply.running ? L10n.text("はい") : L10n.text("いいえ")))
            print(L10n.format("施錠中: %@", reply.locked ? L10n.text("はい") : L10n.text("いいえ")))
        }
    }
}

struct FinderTagsResync: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resync",
        abstract: L10n.text("今すぐ再照合する（メニューの「Finder タグを再照合」と同じ経路・終わるまで待つ）"))
    @OptionGroup var common: CommonOptions
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let data = try client.finderTagResync(uuid: lib.id)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let reply = try JSONDecoder().decode(FinderTagResyncReply.self, from: data)
            switch reply.status {
            case "started":
                print(L10n.format("再照合しました（Finder → 庫 %d 件 / 庫 → Finder %d 件）", reply.updatedInLibrary, reply.updatedInFinder))
            case "noField":
                print(L10n.text("同期する項目が選ばれていません（何もしていません）"))
            case "locked":
                print(L10n.text("施錠されています（解錠するまで再照合しません）"))
            case "alreadyRunning":
                print(L10n.text("すでに再照合が走っています"))
            case "noLibrary":
                print(L10n.text("庫が開いていません"))
            default:
                print(reply.status)
            }
            if !reply.skippedTags.isEmpty {
                print(L10n.format("同期できなかったタグ: %@", reply.skippedTags.joined(separator: " / ")))
            }
            if !reply.skippedBooks.isEmpty {
                print(L10n.plural("タグを読めなかった本: %d 冊", count: reply.skippedBooks.count, reply.skippedBooks.count))
            }
            if !reply.indexingDisabledVolumes.isEmpty {
                print(L10n.format("Spotlight 索引が無効: %@", reply.indexingDisabledVolumes.joined(separator: L10n.text("・"))))
            }
            if let failure = reply.failure {
                print(L10n.format("失敗: %@", failure))
            }
        }
    }
}


struct FinderTagsSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: L10n.text("同期する項目を変える（none で同期しない・前回同期値は消える）"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("項目の列名（genre / series / author / neta / keyword_a / keyword_b / keyword_c）または none")))
    var field: String
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let value: String? = (field == "none" || field.isEmpty) ? nil : field
            let data = try client.finderTagSetField(uuid: lib.id, field: value)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let reply = try JSONDecoder().decode(FinderTagSyncStatusReply.self, from: data)
            print(L10n.format("項目: %@", reply.field ?? L10n.text("（同期しない）")))
        }
    }
}

// MARK: - rename-files（ローカル制御専用・admin）

/// メタデータでファイル名を変える。
///
/// **`--apply` を書かない限りファイルは 1 つも動かない。**既定は計画を出すだけ。
struct RenameFiles: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename-files",
        abstract: L10n.text("メタデータでファイル名を変える（既定は計画のみ・--apply で実行）"))
    @OptionGroup var common: CommonOptions
    @Argument(help: ArgumentHelp(L10n.text("対象の書籍 ID（複数可）"))) var bookIDs: [Int]
    @Option(name: .long, help: ArgumentHelp(L10n.text("使う命名プリセットの ID（省略時は庫の既定）"))) var preset: String?
    @Option(name: .long, help: ArgumentHelp(L10n.text("その場で使う書式（例: \"@series v@volume\"）。--preset とは併用できない")))
    var format: String?
    @Flag(name: .long, help: ArgumentHelp(L10n.text("実際にファイルを改名する（付けなければ計画のみ）"))) var apply = false

    func run() throws {
        try mappingAPIErrors {
            if preset != nil && format != nil {
                throw ValidationError(L10n.text("--preset と --format は同時に指定できません"))
            }
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let body = RenameFilesRequest(ids: bookIDs, presetID: preset, format: format, apply: apply)
            let data = try client.renameFiles(uuid: lib.id, body: body)
            if common.json {
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            let reply = try JSONDecoder().decode(RenameFilesReply.self, from: data)
            switch reply.status {
            case "ok":
                for row in reply.rows {
                    // Codex レビュー P2: 実行時に move / DB 更新が失敗した行は
                    // status が "ok" のまま failure に理由が入る。failure を見ずに
                    // status だけで分岐すると、失敗した行にも成功の矢印が出てしまう。
                    if let failure = row.failure {
                        print(L10n.format("× %@ → %@（失敗: %@）", row.oldName, row.newName, failure))
                    } else if row.status == "ok" {
                        print("→ \(row.oldName) → \(row.newName)")
                    } else {
                        print(L10n.format("× %@ → %@（%@）", row.oldName, row.newName, row.status))
                    }
                }
                if reply.applied {
                    print(L10n.format("改名しました: %d 件 / 見送り %d 件", reply.renamed, reply.skipped))
                } else {
                    let planned = reply.rows.filter { $0.status == "ok" }.count
                    print(L10n.plural("計画のみ（--apply を付けると実行します）: 改名 %d 件予定", count: planned, planned))
                }
                if !reply.missingIDs.isEmpty {
                    print(L10n.format("庫に無い ID: %@", reply.missingIDs.map(String.init).joined(separator: ", ")))
                }
            case "badFormat":
                print(L10n.text("書式が不正です"))
            case "failed":
                print(L10n.format("失敗しました: %@", reply.failure ?? L10n.text("理由不明")))
            case "noLibrary":
                print(L10n.text("庫が開いていません"))
            default:
                print(reply.status)
            }
        }
    }
}
