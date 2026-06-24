// SPDX-License-Identifier: MIT
import Foundation
import ArgumentParser
import LibraryServerAPI

// MARK: - Entry Point

@main
struct Stacknest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stacknest-cli",
        abstract: "StackNest ライブラリ操作 CLI",
        subcommands: [Libraries.self, List.self, Add.self, Rm.self, Set.self]
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
            switch e {
            case .http(let s) where s == 401 || s == 403:
                fputs("エラー: 認証に失敗しました（HTTP \(s)）。トークンを確認してください（設定 ▸ ローカルアクセス ▸ 再生成、または --token で指定）。\n", stderr)
            case .notFound:
                fputs("エラー: 対象が見つかりません（HTTP 404）。\n", stderr)
            case .http(let s):
                fputs("エラー: サーバが HTTP \(s) を返しました。\n", stderr)
            case .network:
                fputs("エラー: サーバに接続できません。\nStackNest を起動し「ローカルアクセスを許可」が ON か確認してください（または --url / --token）。\n", stderr)
            case .decode:
                fputs("エラー: サーバ応答を解釈できませんでした。\n", stderr)
            }
            throw ExitCode(2)
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
        abstract: "ライブラリの書籍一覧を表示する"
    )
    @OptionGroup var common: CommonOptions
    @Option(name: .shortAndLong, help: "検索キーワード")
    var query: String?
    @Option(name: .shortAndLong, help: "取得件数（既定 100・最大 500）")
    var limit: Int?

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            let data = try client.listBooks(uuid: lib.id, query: query, limit: limit)
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

    func run() throws {
        try mappingAPIErrors {
            let ep = try resolveEndpoint(common: common)
            let client = APIClient(endpoint: ep)
            let lib = try resolveLibrary(client: client, libArg: common.library)
            // volume: CLI は Int? で受け取り、BookPatchDTO は Double? なので変換
            let volumeDouble: Double? = volume.map { Double($0) }
            let patch = BookPatchDTO(
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
            try client.patch(uuid: lib.id, id: id, body: patch)
            if !common.json {
                print("更新しました (id=\(id))")
            }
        }
    }
}
