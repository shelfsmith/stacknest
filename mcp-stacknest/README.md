# stacknest MCP サーバ

StackNest ライブラリを MCP 経由で操作する（`stacknest` CLI を subprocess ラップ）。
StackNest.app を起動し「設定 ▸ 共有 ▸ ローカルアクセス」が ON である必要がある。

## セットアップ

```bash
cd mcp-stacknest
python3 -m venv .venv
./.venv/bin/pip install -U pip
./.venv/bin/pip install -r requirements.txt
```

## Claude Code への登録（`~/.claude.json` の mcpServers）

```json
"stacknest": {
  "type": "stdio",
  "command": "<repo>/mcp-stacknest/.venv/bin/python",
  "args": ["<repo>/mcp-stacknest/server.py"]
}
```

`<repo>` は `.../homelab/stacknest`。

`STACKNEST_CLI` は**任意**（通常は不要）。
MCP は起動時に次の順で `stacknest-cli` を自動解決する:

1. 環境変数 `STACKNEST_CLI` が設定されていればその値を使う
2. StackNest.app が起動時に `app.shelfsmith.stacknest` → `cli_path` へ記録した同梱 CLI の絶対パスを使う（`StackNest.app/Contents/Helpers/stacknest-cli`）
3. PATH 上の `stacknest-cli` にフォールバック

通常は StackNest.app を一度起動するだけで同梱 CLI が自動解決されるため、`STACKNEST_CLI` の設定は不要。
カスタムパスを使いたい場合のみ `env.STACKNEST_CLI` を指定する:

```json
"stacknest": {
  "type": "stdio",
  "command": "<repo>/mcp-stacknest/.venv/bin/python",
  "args": ["<repo>/mcp-stacknest/server.py"],
  "env": { "STACKNEST_CLI": "/path/to/stacknest-cli" }
}
```

登録後は Claude Code を再起動して MCP を読み込む。

## ツール

- `stacknest_libraries()` — ライブラリ一覧（id/name/bookCount/locked）。
- `stacknest_list(library, query?, limit?)` — 書籍一覧（items に id＋メタ、total に総数。limit 最大 500）。
- `stacknest_detail(library, id)` — 書籍 1 件の全メタデータ。
- `stacknest_facets(library, field)` — 指定フィールド（author/genre 等）の distinct 値一覧。
- `stacknest_shelves(library)` — 棚（スマート棚・手動棚）一覧。
- `stacknest_me()` — 接続トークンの権限情報（role/tier/scope）。
- `stacknest_add(library, paths[], preset?)` — サーバローカルのパスを追加（in-place）。
- `stacknest_set(library, id, title?/author?/series?/volume?/genre?/keyword_a?/keyword_b?/memo?/neta?/rating?/unseen?/book_type?/direction?)` — メタ編集。`unseen` は bool、`book_type` は整数、`direction` は `ltr`/`rtl`。
- `stacknest_remove(library, ids[], trash?)` — 削除（破壊的・`trash=True` で実ファイルを macOS ゴミ箱へ）。

`library` はライブラリ名または UUID（`stacknest_libraries` で確認）。`id` は `stacknest_list`/`stacknest_detail` で取得。

## 接続先

接続先は CLI が同一 Mac の UserDefaults（`app.shelfsmith.stacknest`）から自動検出する。
リモート等を使う場合は `STACKNEST_URL` / `STACKNEST_TOKEN` を env に設定すれば CLI へ透過する。

## テスト

```bash
./.venv/bin/python -m pytest tests/ -q
```
（`cli.py` の純ロジック＝argv 組み立て・JSON パース・終了コード→例外。subprocess はモック）
