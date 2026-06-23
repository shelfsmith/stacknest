# stacknest MCP サーバ

StackNest ライブラリを MCP 経由で操作する（`stacknest` CLI を subprocess ラップ）。
StackNest.app を起動し「設定 ▸ 共有 ▸ ローカル自動化」が ON である必要がある。

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
  "args": ["<repo>/mcp-stacknest/server.py"],
  "env": { "STACKNEST_CLI": "<repo>/dist/stacknest" }
}
```

`<repo>` は `.../homelab/stacknest`。`STACKNEST_CLI` 未指定時は PATH の `stacknest` を使う。
登録後は Claude Code を再起動して MCP を読み込む。

## ツール

- `stacknest_libraries()` — ライブラリ一覧（id/name/bookCount/locked）。
- `stacknest_list(library, query?, limit?)` — 書籍一覧（items に id＋メタ、total に総数。limit 最大 500）。
- `stacknest_add(library, paths[], preset?)` — サーバローカルのパスを追加（in-place）。
- `stacknest_set(library, id, title?/author?/series?/volume?/genre?/keyword_a?/keyword_b?/memo?/neta?/rating?)` — メタ編集。
- `stacknest_remove(library, ids[], trash?)` — 削除（破壊的・`trash=True` で実ファイルを macOS ゴミ箱へ）。

`library` はライブラリ名または UUID（`stacknest_libraries` で確認）。`id` は `stacknest_list` で取得。

## 接続先

接続先は CLI が同一 Mac の UserDefaults（`app.shelfsmith.stacknest`）から自動検出する。
リモート等を使う場合は `STACKNEST_URL` / `STACKNEST_TOKEN` を env に設定すれば CLI へ透過する。

## テスト

```bash
./.venv/bin/python -m pytest tests/ -q
```
（`cli.py` の純ロジック＝argv 組み立て・JSON パース・終了コード→例外。subprocess はモック）
