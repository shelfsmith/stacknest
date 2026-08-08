# stacknest MCP サーバ

StackNest ライブラリを MCP 経由で操作します（`stacknest-cli` を subprocess でラップします）。
StackNest.app を起動し「設定 ▸ 一般 ▸ ローカルアクセス」が ON になっている必要があります。

## セットアップ

```bash
cd mcp-stacknest
python3 -m venv .venv
./.venv/bin/pip install -U pip
./.venv/bin/pip install -r requirements.txt
```

**既存の `.venv` を作り直さずに依存だけ入れ直す場合**は、その venv がどう作られたかで
コマンドが変わる。現在の `.venv` は `uv` 製で **`pip` が同梱されていない**ため、
上のコマンドは `No such file or directory` になる（2026-08-08 の復旧時に判明）。

```bash
uv pip install -r requirements.txt --python .venv/bin/python
```

依存が壊れているか確かめるには、`server.py` が import できるかを見るのが速い:

```bash
./.venv/bin/python -c "import server; print('server module OK')"
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
MCP は起動時に次の順で `stacknest-cli` を自動解決します:

1. 環境変数 `STACKNEST_CLI` が設定されていればその値を使います
2. StackNest.app が起動時に `app.shelfsmith.stacknest` → `cli_path` へ記録した同梱 CLI の絶対パスを使います（`StackNest.app/Contents/Helpers/stacknest-cli`）
3. PATH 上の `stacknest-cli` にフォールバックします

通常は StackNest.app を一度起動するだけで同梱 CLI が自動解決されるため、`STACKNEST_CLI` の設定は不要です。
カスタムパスを使いたい場合のみ `env.STACKNEST_CLI` を指定します:

```json
"stacknest": {
  "type": "stdio",
  "command": "<repo>/mcp-stacknest/.venv/bin/python",
  "args": ["<repo>/mcp-stacknest/server.py"],
  "env": { "STACKNEST_CLI": "/path/to/stacknest-cli" }
}
```

登録後は Claude Code を再起動して MCP を読み込みます。

## ツール

### ライブラリと書籍（基本）

- `stacknest_libraries()` — ライブラリ一覧（id/name/bookCount/locked）。
- `stacknest_list(library, query?, limit?)` — 書籍一覧（items に id とメタ、total に総数。limit 最大 500）。
- `stacknest_detail(library, id)` — 書籍 1 件の全メタデータ。
- `stacknest_facets(library, field)` — 指定フィールド（author/genre 等）の distinct 値一覧。
- `stacknest_me()` — 接続トークンの権限情報（role/tier/scope）。
- `stacknest_add(library, paths[], preset?)` — サーバローカルのパスを追加（in-place）。
- `stacknest_set(library, id, title?/author?/series?/volume?/genre?/keyword_a?/keyword_b?/memo?/neta?/rating?/unseen?/book_type?/direction?)` — メタ編集。`unseen` は bool、`book_type` は整数、`direction` は `ltr`/`rtl`。
- `stacknest_remove(library, ids[], trash?)` — 削除（破壊的、`trash=True` で実ファイルを macOS ゴミ箱へ）。

### 棚（shelf）CRUD

- `stacknest_shelves(library)` — 棚（スマート棚と手動棚）一覧。
- `stacknest_shelf_create(library, title, smart?, conditions?)` — 棚を作成。`smart=True` でスマート棚、`conditions` に条件 dict を渡す。
- `stacknest_shelf_delete(library, shelf_id)` — 棚を削除（中身の本はライブラリに残る）。
- `stacknest_shelf_rename(library, shelf_id, title)` — 棚をリネーム。
- `stacknest_shelf_conditions_get(library, shelf_id)` — スマート棚の条件 JSON を取得。
- `stacknest_shelf_conditions_set(library, shelf_id, conditions)` — スマート棚の条件 JSON を更新。
- `stacknest_shelf_add_books(library, shelf_id, ids[])` — 手動棚に本を追加。
- `stacknest_shelf_remove_books(library, shelf_id, ids[])` — 手動棚から本を除く。

### フォルダ監視（watch）

- `stacknest_watch_get(library)` — 自動監視フォルダ設定を取得。
- `stacknest_watch_set(library, config)` — 自動監視フォルダ設定を更新。`config` は `{"folders":["/path"],"preset":"standard"}` 形式。

### ロック（lock）

- `stacknest_lock_set(library, password)` — パスワードロックを設定。**パスワードは CLI の stdin 経由で渡し、プロセスの argv には露出しない**（セキュア）。
- `stacknest_lock_clear(library)` — パスワードロックを解除。

### インポート設定（import-config）

- `stacknest_import_config_get(library)` — ライブラリのインポート設定を取得。
- `stacknest_import_config_set(library, auto_classify?, thick?, preset?)` — ライブラリのインポート設定を更新。
- `stacknest_import_config_global_get()` — グローバルインポート設定を取得。
- `stacknest_import_config_global_set(auto_classify?, thick?, preset?)` — グローバルインポート設定を更新。

### リンク修復と重複検出

- `stacknest_relink(library, id, new_path)` — ファイル移動後のリンク修復（本の絶対パスを更新）。
- `stacknest_dedup_scan(library, query?)` — 重複候補を検出してリストを返す。

`library` はライブラリ名または UUID です（`stacknest_libraries` で確認できます）。`id`/`shelf_id` は各 list/shelves ツールで取得できます。

## ロックのセキュリティ設計

`stacknest_lock_set` はパスワードを `--password-stdin` フラグで受け取る CLI モードを使用します。
パスワード文字列は `subprocess.run(..., input=password)` で **stdin** として渡すため、プロセスリスト（`ps aux` 等）に露出しません。

## 接続先

接続先は CLI が同一 Mac の UserDefaults（`app.shelfsmith.stacknest`）から自動検出します。
リモート等を使う場合は `STACKNEST_URL` / `STACKNEST_TOKEN` を env に設定すれば CLI へ透過します。

## テスト

```bash
./.venv/bin/python -m pytest tests/ -q
```
（`cli.py` の純ロジック、すなわち argv 組み立て / JSON パース / 終了コードから例外への変換。subprocess はモックします）
