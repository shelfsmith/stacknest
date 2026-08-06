// SPDX-License-Identifier: MIT
import Foundation
import ArgumentParser
import LibraryServerAPI
import StackroomFormat

// MARK: - Entry Point

@main
struct Stacknest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stacknest-cli",
        abstract: "StackNest ライブラリ操作 CLI",
        subcommands: [Libraries.self, List.self, Add.self, Rm.self, Set.self,
                      Detail.self, Facets.self, Shelves.self, Me.self,
                      Shelf.self, Watch.self, Lock.self, ImportConfigCmd.self,
                      ImportConfigGlobal.self, Relink.self, Dedup.self, Unlock.self,
                      Grant.self, Stamp.self, StampDefinitions.self, Label.self,
                      Integrity.self]
    )
}

// MARK: - 共通オプション

struct CommonOptions: ParsableArguments {
    @Option(name: .long, help: "StackNest サーバの URL（例: http://127.0.0.1:8765）")
    var url: String?

    @Option(name: .long, help: "アクセストークン")
    var token: String?

    @Option(name: [.customShort("L"), .long], help: "ライブラリ名または UUID")
    var library: String?

    @Flag(name: .long, help: "JSON 形式で出力する")
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
                fputs("エラー: アクセスが拒否されました（HTTP 403）。ロック庫の場合はライブラリトークン（env STACKNEST_LIBRARY_TOKEN）が失効している可能性があります。unlock で再取得してください。\n", stderr)
                code = 3
            case .http(let s) where s == 401:
                fputs("エラー: 認証に失敗しました（HTTP 401）。トークンを確認してください（設定 ▸ ローカルアクセス ▸ 再生成、または --token で指定）。\n", stderr)
                code = 2
            case .notFound:
                fputs("エラー: 対象が見つかりません（HTTP 404）。\n", stderr)
                code = 2
            case .http(let s):
                fputs("エラー: サーバが HTTP \(s) を返しました。\n", stderr)
                code = 2
            case .network:
                fputs("エラー: サーバに接続できません。\nStackNest を起動し「ローカルアクセスを許可」が ON か確認してください（または --url / --token）。\n", stderr)
                code = 2
            case .decode:
                fputs("エラー: サーバ応答を解釈できませんでした。\n", stderr)
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
            fputs("エラー: 接続先を解決できませんでした。\nStackNest を起動し「ローカルアクセスを許可」が ON か確認してください。\n--url / --token で明示指定することもできます。\n", stderr)
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
            fputs("エラー: 開いているライブラリがありません。StackNest でライブラリを開いてください。\n", stderr)
            throw ExitCode(2)
        }
        guard let arg = libArg else {
            if libs.count == 1 { return libs[0] }
            fputs("エラー: ライブラリが複数あります。--library で指定してください:\n", stderr)
            for lib in libs { fputs("  \(lib.id)  \(lib.name)\n", stderr) }
            throw ExitCode(2)
        }
        let matches = libs.filter { $0.id == arg || $0.name == arg }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            fputs("エラー: 名前「\(arg)」が複数のライブラリに一致します。UUID で指定してください:\n", stderr)
            for lib in matches { fputs("  \(lib.id)  \(lib.name)\n", stderr) }
            throw ExitCode(2)
        }
        fputs("エラー: ライブラリ「\(arg)」が見つかりません。\n", stderr)
        throw ExitCode(2)
    }
}

// MARK: - libraries

struct Libraries: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "libraries",
        abstract: "開いているライブラリ一覧を表示する"
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
                print("\(lib.id)  \(lib.name)  (\(lib.bookCount) 冊)\(lib.locked ? " [ロック]" : "")")
            }
        }
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "ライブラリの書籍一覧を表示する（検索/フィルタ/ブラウズ/ソート対応）"
    )
    @OptionGroup var common: CommonOptions
    @Option(name: .shortAndLong, help: "検索キーワード")
    var query: String?
    @Option(name: .shortAndLong, help: "取得件数（既定 100・最大 500）")
    var limit: Int?
    @Option(name: .long, help: "ソートキー（例: title, dateAdded）")
    var sort: String?
    @Option(name: .long, help: "並び順 (asc/desc)")
    var order: String?
    @Option(name: .long, help: "サイドバースコープ（例: all, recent, shelf）")
    var scope: String?
    @Option(name: [.customLong("scope-id")], help: "スコープ対象 ID（棚 ID 等）")
    var scopeId: Int64?
    @Option(name: [.customLong("recent-days")], help: "scope=recent の日数")
    var recentDays: Int?
    @Option(name: .long, help: "追加フィールドをカンマ区切りで要求（genre,neta,keywordA,...）")
    var fields: String?
    @Option(name: [.customLong("filter-json")], help: "FilterState の JSON")
    var filterJSON: String?
    @Option(name: [.customLong("browse-json")], help: "ブラウズ条件 JSON（[{\"column\":...,\"value\":...}]）")
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
            print("--- 表示 \(page.items.count) / 計 \(page.total) 冊 ---")
        }
    }
}

// MARK: - add

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "書籍ファイルをライブラリに追加する"
    )
    @OptionGroup var common: CommonOptions
    @Argument(help: "追加するファイルまたはフォルダのパス（複数可）")
    var paths: [String]
    @Option(name: .long, help: "取り込みプリセット ID")
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
                print("追加: \(reply.addedIDs.count) 冊 (IDs: \(reply.addedIDs.map(String.init).joined(separator: ",")))")
                if !reply.alreadyPresent.isEmpty {
                    print("既存: \(reply.alreadyPresent.joined(separator: ", "))")
                }
                if !reply.failed.isEmpty {
                    fputs("失敗: \(reply.failed.joined(separator: ", "))\n", stderr)
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
        abstract: "書籍をライブラリから削除する"
    )
    @OptionGroup var common: CommonOptions
    // I-2: 複数 ID 対応
    @Argument(help: "削除する書籍の ID（複数可）")
    var ids: [Int]
    @Flag(name: .long, help: "ゴミ箱に移動する（既定: DB から削除のみ）")
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
                        print("削除しました (id=\(id))")
                    }
                } catch {
                    fputs("エラー (id=\(id)): \(error)\n", stderr)
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
        abstract: "書籍のメタデータを更新する"
    )
    @OptionGroup var common: CommonOptions
    @Argument(help: "対象書籍の ID")
    var id: Int
    // I-3: spec §3.4 の全メタ文字列/数値フィールドを追加（unseen は除外）
    @Option(name: .long, help: "タイトル")
    var title: String?
    @Option(name: .long, help: "著者")
    var author: String?
    @Option(name: .long, help: "シリーズ名")
    var series: String?
    @Option(name: .long, help: "巻番号")
    var volume: Int?
    @Option(name: .long, help: "ジャンル")
    var genre: String?
    @Option(name: [.customLong("keyword-a")], help: "キーワード A")
    var keywordA: String?
    @Option(name: [.customLong("keyword-b")], help: "キーワード B")
    var keywordB: String?
    @Option(name: .long, help: "メモ")
    var memo: String?
    @Option(name: .long, help: "ネタ")
    var neta: String?
    @Option(name: .long, help: "レーティング (0-5)")
    var rating: Int?
    @Option(name: .long, help: "未読フラグ (true/false)")
    var unseen: Bool?
    @Option(name: [.customLong("book-type")], help: "本の種類 (整数)")
    var bookType: Int?
    @Option(name: .long, help: "読み方向 (ltr/rtl/clear)")
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
                    throw ValidationError("--direction は ltr / rtl / clear のいずれかを指定してください")
                }
                if direction == "clear" { patch.clearPageDirection = true } else { patch.pageDirection = direction }
            }
            try client.patch(uuid: lib.id, id: id, body: patch)
            if !common.json {
                print("更新しました (id=\(id))")
            }
        }
    }
}

// MARK: - detail

struct Detail: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detail",
        abstract: "書籍の詳細情報を表示する"
    )
    @OptionGroup var common: CommonOptions
    @Argument(help: "書籍 ID")
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
        abstract: "指定フィールドの distinct 値一覧を表示する"
    )
    @OptionGroup var common: CommonOptions
    @Argument(help: "フィールド名（例: author, genre, series）")
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
                print("--- \(values.count) 件 ---")
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
        abstract: "ライブラリの棚一覧を表示する"
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
            for shelf in shelfList {
                let kind = shelf.isSmart ? "smart" : "user"
                print("\(shelf.id)\t\(shelf.title)\t[\(kind)]")
            }
        }
    }
}

// MARK: - me

struct Me: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "me",
        abstract: "現在のトークンの権限情報を表示する"
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
            case .all: scopeStr = "all（全ライブラリ）"
            case .libraries(let ids): scopeStr = "\(ids.count) ライブラリ: \(ids.joined(separator: ", "))"
            }
            print("role: \(me.role.rawValue)\ntier: \(me.tier.rawValue)\nscope: \(scopeStr)")
        }
    }
}

// MARK: - shelf グループ

struct Shelf: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shelf", abstract: "棚（スマート/手動）を管理する",
        subcommands: [ShelfCreate.self, ShelfRm.self, ShelfRename.self,
                      ShelfConditionsGet.self, ShelfConditionsSet.self,
                      ShelfAddBooks.self, ShelfRemoveBooks.self])
}
struct ShelfCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "棚を作成する")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "棚名") var title: String
    @Flag(name: .long, help: "スマート棚にする") var smart: Bool = false
    @Option(name: [.customLong("conditions-json")], help: "スマート棚条件 JSON (SmartShelfConditions)") var conditionsJSON: String?
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            var conditions: SmartShelfConditions?
            if let conditionsJSON {
                conditions = try JSONDecoder().decode(SmartShelfConditions.self, from: Data(conditionsJSON.utf8))
            }
            if smart && conditions == nil { throw ValidationError("--smart 時は --conditions-json が必要です") }
            let body = ShelfCreateRequest(title: title, isSmart: smart, conditions: conditions)
            let data = try client.shelfCreate(uuid: lib.id, body: body)
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }
}
struct ShelfRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "棚を削除する")
    @OptionGroup var common: CommonOptions
    @Argument(help: "棚 ID") var id: Int64
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            try client.shelfDelete(uuid: lib.id, id: id)
            print("削除しました (shelf=\(id))")
        }
    }
}
struct ShelfRename: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "棚を改名する")
    @OptionGroup var common: CommonOptions
    @Argument(help: "棚 ID") var id: Int64
    @Option(name: .long, help: "新しい棚名") var title: String
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
    static let configuration = CommandConfiguration(commandName: "conditions-get", abstract: "スマート棚の条件を表示する")
    @OptionGroup var common: CommonOptions
    @Argument(help: "棚 ID") var id: Int64
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            print(String(data: try client.shelfConditionsGet(uuid: lib.id, id: id), encoding: .utf8) ?? "")
        }
    }
}
struct ShelfConditionsSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "conditions-set", abstract: "スマート棚の条件を更新する")
    @OptionGroup var common: CommonOptions
    @Argument(help: "棚 ID") var id: Int64
    @Option(name: [.customLong("conditions-json")], help: "条件 JSON (SmartShelfConditions)") var conditionsJSON: String
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
    static let configuration = CommandConfiguration(commandName: "add-books", abstract: "手動棚に本を追加する")
    @OptionGroup var common: CommonOptions
    @Argument(help: "棚 ID") var id: Int64
    @Argument(help: "追加する書籍 ID（複数可）") var bookIDs: [Int]
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            try client.shelfBooksAdd(uuid: lib.id, id: id, bookIDs: bookIDs)
            print("追加しました (shelf=\(id), books=\(bookIDs.count))")
        }
    }
}
struct ShelfRemoveBooks: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-books", abstract: "手動棚から本を除去する")
    @OptionGroup var common: CommonOptions
    @Argument(help: "棚 ID") var id: Int64
    @Argument(help: "除去する書籍 ID（複数可）") var bookIDs: [Int]
    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            try client.shelfBooksRemove(uuid: lib.id, id: id, bookIDs: bookIDs)
            print("除去しました (shelf=\(id), books=\(bookIDs.count))")
        }
    }
}

// MARK: - watch グループ

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "監視フォルダ設定", subcommands: [WatchGet.self, WatchSet.self])
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
    static let configuration = CommandConfiguration(commandName: "set", abstract: "監視設定を全置換する")
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("config-json")], help: "WatchConfigDTO の JSON") var configJSON: String
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
    static let configuration = CommandConfiguration(commandName: "lock", abstract: "庫ロック (admin)", subcommands: [LockSet.self, LockClear.self])
}
struct LockSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "パスワードロックを設定・変更する（既存ロックの変更には現在のパスワードが必須）")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "新しいパスワード（argv に残るため自動化では --password-stdin 推奨）") var password: String?
    @Flag(name: [.customLong("password-stdin")], help: "新しいパスワードを標準入力から読む（argv 非露出）") var passwordStdin: Bool = false
    @Option(name: .long, help: "現在のパスワード（既存ロックの変更時のみ必須。新規設定時は不要。argv に残るため自動化では --current-password-stdin 推奨）")
    var currentPassword: String?
    @Flag(name: [.customLong("current-password-stdin")],
          help: "現在のパスワードを標準入力から読む（argv 非露出。--password-stdin と併用時は「現在のパスワード\\n新しいパスワード」の2行として読む）")
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
                throw ValidationError("--current-password-stdin と --password-stdin を併用する場合、標準入力に「現在のパスワード\\n新しいパスワード」の2行を渡してください")
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
                throw ValidationError("--password または --password-stdin を指定してください")
            }
        }
        guard !pw.isEmpty else { throw ValidationError("パスワードが空です") }
        if let c = cur, c.isEmpty { cur = nil }
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        try client.lockSet(uuid: lib.id, password: pw, currentPassword: cur); print("ロックを設定しました")
    } }
}
struct LockClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "ロックを解除する（既存ロックがある場合は現在のパスワードが必須）")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "現在のパスワード（既存ロックがある場合は必須。argv に残るため自動化では --current-password-stdin 推奨）")
    var currentPassword: String?
    @Flag(name: [.customLong("current-password-stdin")], help: "現在のパスワードを標準入力から読む（argv 非露出）")
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
        try client.lockClear(uuid: lib.id, currentPassword: cur); print("ロックを解除しました")
    } }
}

// MARK: - import-config グループ（per-library）

struct ImportConfigCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-config", abstract: "取り込み設定 (per-library override)", subcommands: [ImportGet.self, ImportSet.self])
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
    static let configuration = CommandConfiguration(commandName: "set", abstract: "override を設定する（指定分のみ）")
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("auto-classify")], help: "自動分類 (true/false)") var autoClassify: Bool?
    @Option(name: .long, help: "厚い本判定閾値") var thick: Int?
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        let body = ImportConfigDTO(autoClassifyEnabled: autoClassify, thickBookThreshold: thick)
        print(String(data: try client.importPut(uuid: lib.id, body: body), encoding: .utf8) ?? "")
    } }
}

// MARK: - import-config-global グループ（admin）

struct ImportConfigGlobal: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-config-global", abstract: "取り込みグローバル既定 (admin)", subcommands: [ImportGlobalGet.self, ImportGlobalSet.self])
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
    @Option(name: [.customLong("auto-classify")], help: "自動分類 (true/false)") var autoClassify: Bool
    @Option(name: .long, help: "厚い本判定閾値") var thick: Int
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let body = GlobalImportConfigDTO(autoClassifyEnabled: autoClassify, thickBookThreshold: thick)
        print(String(data: try client.importGlobalPut(body: body), encoding: .utf8) ?? "")
    } }
}

// MARK: - unlock

struct Unlock: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "ロック庫を解錠し短命ライブラリトークンを取得する（以後 env STACKNEST_LIBRARY_TOKEN に設定して使う）")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "パスワード（argv に残るため自動化では --password-stdin 推奨）") var password: String?
    @Flag(name: [.customLong("password-stdin")], help: "パスワードを標準入力から読む（argv 非露出）") var passwordStdin: Bool = false
    func run() throws { try mappingAPIErrors {
        let pw: String
        if passwordStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            pw = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let password {
            pw = password
        } else {
            throw ValidationError("--password または --password-stdin を指定してください")
        }
        guard !pw.isEmpty else { throw ValidationError("パスワードが空です") }
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
    static let configuration = CommandConfiguration(commandName: "relink", abstract: "本のパスを再リンクする")
    @OptionGroup var common: CommonOptions
    @Argument(help: "書籍 ID") var id: Int
    @Option(name: [.customLong("new-path")], help: "新しいパス") var newPath: String
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        try client.relink(uuid: lib.id, id: id, newPath: newPath); print("再リンクしました (id=\(id))")
    } }
}
struct Dedup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dedup", abstract: "重複スキャンを実行する")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.dedup(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}

// MARK: - integrity グループ（整合性検査・G27a）

struct Integrity: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "integrity", abstract: "蔵書の整合性を検査する",
        subcommands: [IntegrityScanCmd.self, IntegrityStatusCmd.self, IntegrityListCmd.self,
                      IntegrityFullScanCmd.self, IntegrityJobStatusCmd.self, IntegrityCancelCmd.self])
}

struct IntegrityScanCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan", abstract: "pages 未取得の本を開いて分類する（簡易チェック）")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.integrityScan(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}

struct IntegrityStatusCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "検査済/未検査/破損/劣化の件数を表示する")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.integritySummary(uuid: lib.id), encoding: .utf8) ?? "")
    } }
}

struct IntegrityListCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "指定した状態の本を一覧する")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "ok / damaged / empty / missing / unsupported（既定: damaged）")
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
        abstract: "全冊 CRC 検証を非同期ジョブとして開始する（数千冊規模で数十時間かかりうる・完走は待たない）")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "unchecked（既定・未検査のみ）/ all（全件再検査）/ damaged（前回破損のみ再検査）")
    var mode: String = "unchecked"

    func run() throws {
        guard fullScanValidModes.contains(mode) else {
            fputs("エラー: --mode は unchecked/all/damaged のいずれかです（指定値: \(mode)）\n", stderr)
            throw ExitCode(2)
        }
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            do {
                _ = try client.startFullScan(uuid: lib.id, mode: mode)
            } catch APIError.http(409) {
                print("既に実行中のメンテナンスジョブがあります。`stacknest-cli integrity job-status` で状況を確認してください。")
                return
            }
            print("""
            フルスキャン（mode=\(mode)）を開始しました。バックグラウンドジョブとして動作します。
            実測値: 約 4.5 秒/冊 ―― 蔵書規模によっては数十時間（例: 22,880 冊で約 31 時間）かかります。
            このコマンドは完走を待たずに終了しました。進捗・中断は以下で行ってください:
              進捗確認: stacknest-cli integrity job-status
              中断:     stacknest-cli integrity cancel
            """)
        }
    }
}

struct IntegrityJobStatusCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "job-status",
        abstract: "実行中のメンテナンスジョブ（full-scan 含む）の進捗を表示する")
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
        abstract: "実行中のメンテナンスジョブ（full-scan 含む）を中断する（実行中ジョブが無ければ no-op）")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        try client.maintenanceCancel(uuid: lib.id)
        print("中断リクエストを送信しました。")
    } }
}

// MARK: - grant グループ（admin）

/// --scope / --scope-libraries / --scope-json から GrantScope を解決する共通ヘルパ。
/// いずれも未指定なら nil（update では「変更しない」、create では呼び出し側が .all 既定にする）。
enum GrantScopeArg {
    static func resolve(scope: String?, scopeLibraries: String?, scopeJSON: String?) throws -> GrantScope? {
        let specified = [scope, scopeLibraries, scopeJSON].compactMap { $0 }
        if specified.count > 1 {
            throw ValidationError("--scope / --scope-libraries / --scope-json は同時指定できません")
        }
        if let scopeJSON {
            return try JSONDecoder().decode(GrantScope.self, from: Data(scopeJSON.utf8))
        }
        if let scopeLibraries {
            let ids = scopeLibraries.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .libraries(ids)
        }
        if let scope {
            guard scope == "all" else { throw ValidationError("--scope は all のみ指定可能（個別指定は --scope-libraries）") }
            return .all
        }
        return nil
    }
}

struct Grant: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grant", abstract: "アクセスグラントを管理する (admin)",
        subcommands: [GrantList.self, GrantCreate.self, GrantUpdate.self, GrantRm.self])
}
struct GrantList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "グラント一覧を表示する")
    @OptionGroup var common: CommonOptions
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let data = try client.grantList()
        if common.json { print(String(data: data, encoding: .utf8) ?? ""); return }
        let grants = try JSONDecoder().decode([GrantDTO].self, from: data)
        for g in grants {
            let scopeStr: String
            switch g.scope {
            case .all: scopeStr = "all"
            case .libraries(let ids): scopeStr = ids.joined(separator: ",")
            }
            print("\(g.id)\t\(g.tier.rawValue)\t\(g.label)\t[\(scopeStr)]")
        }
    } }
}
struct GrantCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "グラントを作成する（token を返す）")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "ラベル") var label: String
    @Option(name: .long, help: "権限階層 (read/edit/admin)") var tier: String
    @Option(name: .long, help: "スコープ all（全ライブラリ）") var scope: String?
    @Option(name: [.customLong("scope-libraries")], help: "対象ライブラリ UUID をカンマ区切りで指定") var scopeLibraries: String?
    @Option(name: [.customLong("scope-json")], help: "GrantScope の JSON を直接指定") var scopeJSON: String?
    func run() throws { try mappingAPIErrors {
        guard let t = AccessTier(rawValue: tier) else { throw ValidationError("--tier は read / edit / admin のいずれか") }
        let resolved = try GrantScopeArg.resolve(scope: scope, scopeLibraries: scopeLibraries, scopeJSON: scopeJSON)
        let body = GrantCreateRequest(label: label, tier: t, scope: resolved ?? .all)
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        print(String(data: try client.grantCreate(body: body), encoding: .utf8) ?? "")
    } }
}
struct GrantUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "グラントを更新する（指定分のみ）")
    @OptionGroup var common: CommonOptions
    @Argument(help: "グラント ID") var id: String
    @Option(name: .long, help: "ラベル") var label: String?
    @Option(name: .long, help: "権限階層 (read/edit/admin)") var tier: String?
    @Option(name: .long, help: "スコープ all") var scope: String?
    @Option(name: [.customLong("scope-libraries")], help: "対象ライブラリ UUID をカンマ区切り") var scopeLibraries: String?
    @Option(name: [.customLong("scope-json")], help: "GrantScope の JSON") var scopeJSON: String?
    func run() throws { try mappingAPIErrors {
        var t: AccessTier?
        if let tier {
            guard let parsed = AccessTier(rawValue: tier) else { throw ValidationError("--tier は read / edit / admin のいずれか") }
            t = parsed
        }
        let resolved = try GrantScopeArg.resolve(scope: scope, scopeLibraries: scopeLibraries, scopeJSON: scopeJSON)
        let body = GrantUpdateRequest(label: label, tier: t, scope: resolved)
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        print(String(data: try client.grantUpdate(id: id, body: body), encoding: .utf8) ?? "")
    } }
}
struct GrantRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "グラントを削除する")
    @OptionGroup var common: CommonOptions
    @Argument(help: "グラント ID") var id: String
    func run() throws { try mappingAPIErrors {
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        try client.grantDelete(id: id); print("削除しました (grant=\(id))")
    } }
}

// MARK: - stamp（一括スタンプ適用・edit）

struct Stamp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stamp", abstract: "複数の本に値を一括スタンプ（追記）/クリアする")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "対象フィールド（例: genre, keyword_a）") var field: String
    @Option(name: .long, help: "追記する値（--clear と排他）") var value: String?
    @Flag(name: .long, help: "値をクリアする（--value と排他）") var clear: Bool = false
    @Argument(help: "対象書籍 ID（複数可）") var bookIDs: [Int]
    func run() throws { try mappingAPIErrors {
        if (value == nil) == (clear == false) {
            throw ValidationError("--value または --clear のいずれか一方を指定してください")
        }
        guard !bookIDs.isEmpty else { throw ValidationError("対象書籍 ID を 1 件以上指定してください") }
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        let body = StampApplyRequest(field: field, value: value, clear: clear ? true : nil, bookIDs: bookIDs)
        let data = try client.stampApply(uuid: lib.id, body: body)
        if common.json { print(String(data: data, encoding: .utf8) ?? ""); return }
        let reply = try JSONDecoder().decode(StampApplyReply.self, from: data)
        print("更新: \(reply.updated) 冊")
    } }
}

// MARK: - stamp-definitions（スタンプ定義の取得/全置換・edit）

struct StampDefinitions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stamp-definitions", abstract: "スタンプ定義を取得/更新する",
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
    static let configuration = CommandConfiguration(commandName: "set", abstract: "スタンプ定義を全置換する")
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("definitions-json")], help: "StampDefinitionsDTO の JSON") var definitionsJSON: String
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
        commandName: "label", abstract: "ラベルカスタマイズを取得/更新する",
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
    static let configuration = CommandConfiguration(commandName: "set", abstract: "ラベルカスタマイズを更新する")
    @OptionGroup var common: CommonOptions
    @Option(name: [.customLong("settings-json")], help: "LabelSettingsDTO の JSON ({customFieldLabels,customBookTypeLabels})") var settingsJSON: String
    func run() throws { try mappingAPIErrors {
        let dto = try JSONDecoder().decode(LabelSettingsDTO.self, from: Data(settingsJSON.utf8))
        let body = try JSONEncoder().encode(dto)
        let ep = try resolveEndpoint(common: common); let client = APIClient(endpoint: ep)
        let lib = try resolveLibrary(client: client, libArg: common.library)
        print(String(data: try client.labelPut(uuid: lib.id, json: body), encoding: .utf8) ?? "")
    } }
}
