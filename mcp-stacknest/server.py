# SPDX-License-Identifier: MIT
"""StackNest MCP サーバ。stacknest CLI をラップして MCP ツールとして公開する。
接続は CLI が同一 Mac の UserDefaults から自動検出（StackNest 起動＋ローカルアクセス ON が前提）。"""
from __future__ import annotations

import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cli  # noqa: E402

from mcp.server.fastmcp import FastMCP  # noqa: E402

mcp = FastMCP("stacknest")


@mcp.tool()
def stacknest_libraries() -> Any:
    """開いている StackNest ライブラリの一覧（id/name/bookCount/locked）を返す。"""
    return cli.libraries()


@mcp.tool()
def stacknest_list(library: str, query: str | None = None, limit: int | None = None) -> Any:
    """ライブラリの書籍一覧を返す（items に各本の id とメタ、total に総数）。
    library はライブラリ名または UUID（stacknest_libraries で確認）。query で検索、limit で件数（最大500）。"""
    return cli.list_books(library, query=query, limit=limit)


@mcp.tool()
def stacknest_add(library: str, paths: list[str], preset: str | None = None) -> Any:
    """サーバローカルのファイル/フォルダパスを本としてライブラリに追加する（in-place・移動しない）。
    返り値の addedIDs が追加された本の id。alreadyPresent は既登録、failed は失敗パス。"""
    return cli.add(library, paths, preset=preset)


@mcp.tool()
def stacknest_set(library: str, id: int, title: str | None = None, author: str | None = None,
                  series: str | None = None, volume: int | None = None, genre: str | None = None,
                  keyword_a: str | None = None, keyword_b: str | None = None,
                  memo: str | None = None, neta: str | None = None, rating: int | None = None,
                  unseen: bool | None = None, book_type: int | None = None,
                  direction: str | None = None) -> str:
    """書籍のメタデータを更新する（指定したフィールドのみ）。id は stacknest_list で取得する。
    unseen: 未読フラグ（true/false）。book_type: 本の種別（整数）。direction: 読み方向（ltr/rtl）。"""
    cli.set_meta(library, id, title=title, author=author, series=series, volume=volume,
                 genre=genre, keyword_a=keyword_a, keyword_b=keyword_b,
                 memo=memo, neta=neta, rating=rating,
                 unseen=unseen, book_type=book_type, direction=direction)
    return f"updated book {id}"


@mcp.tool()
def stacknest_remove(library: str, ids: list[int], trash: bool = False) -> str:
    """書籍をライブラリから削除する（破壊的）。既定は DB エントリのみ削除し実ファイルは残す。
    trash=True で実ファイルを macOS ゴミ箱へ移動（復元可）。id は stacknest_list で取得する。"""
    cli.remove(library, ids, trash=trash)
    return f"removed {len(ids)} book(s)"


@mcp.tool()
def stacknest_detail(library: str, id: int) -> Any:
    """書籍 1 件の全メタデータを返す。id は stacknest_list で取得する。"""
    return cli.detail(library, id)


@mcp.tool()
def stacknest_facets(library: str, field: str) -> Any:
    """指定フィールド（author/genre 等）の distinct 値一覧を返す。"""
    return cli.facets(library, field)


@mcp.tool()
def stacknest_shelves(library: str) -> Any:
    """ライブラリの棚（スマート棚・手動棚）一覧を返す。"""
    return cli.shelves(library)


@mcp.tool()
def stacknest_me() -> Any:
    """接続トークンの権限情報（role/tier/scope）を返す。"""
    return cli.me()


# --- 棚（shelf）CRUD ---

@mcp.tool()
def stacknest_shelf_create(library: str, title: str,
                           smart: bool = False,
                           conditions: dict | None = None) -> Any:
    """棚を作成する。smart=True でスマート棚（conditions で条件 JSON を渡す）、
    False で手動棚。返り値に新棚の id が含まれる。"""
    return cli.shelf_create(library, title, smart=smart, conditions=conditions)


@mcp.tool()
def stacknest_shelf_delete(library: str, shelf_id: int) -> str:
    """棚を削除する（中身の本はライブラリに残る）。shelf_id は stacknest_shelves で取得。"""
    cli.shelf_delete(library, shelf_id)
    return f"deleted shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_rename(library: str, shelf_id: int, title: str) -> str:
    """棚をリネームする。"""
    cli.shelf_rename(library, shelf_id, title)
    return f"renamed shelf {shelf_id} to {title!r}"


@mcp.tool()
def stacknest_shelf_conditions_get(library: str, shelf_id: int) -> Any:
    """スマート棚の条件 JSON を取得する。"""
    return cli.shelf_conditions_get(library, shelf_id)


@mcp.tool()
def stacknest_shelf_conditions_set(library: str, shelf_id: int, conditions: dict) -> str:
    """スマート棚の条件 JSON を更新する。conditions は {"version":1,"match":"all","rules":[...]} 形式。"""
    cli.shelf_conditions_set(library, shelf_id, conditions)
    return f"updated conditions for shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_add_books(library: str, shelf_id: int, ids: list[int]) -> str:
    """手動棚に本を追加する。ids は stacknest_list で取得した本の id リスト。"""
    cli.shelf_add_books(library, shelf_id, ids)
    return f"added {len(ids)} book(s) to shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_remove_books(library: str, shelf_id: int, ids: list[int]) -> str:
    """手動棚から本を除く（本自体はライブラリに残る）。"""
    cli.shelf_remove_books(library, shelf_id, ids)
    return f"removed {len(ids)} book(s) from shelf {shelf_id}"


# --- フォルダ監視（watch）---

@mcp.tool()
def stacknest_watch_get(library: str) -> Any:
    """ライブラリの自動監視フォルダ設定を取得する。"""
    return cli.watch_get(library)


@mcp.tool()
def stacknest_watch_set(library: str, config: dict) -> str:
    """ライブラリの自動監視フォルダ設定を更新する。
    config は {"folders":["/path/to/dir"],"preset":"standard"} 等の形式。"""
    cli.watch_set(library, config)
    return "watch config updated"


# --- ロック（lock）---

@mcp.tool()
def stacknest_lock_set(library: str, password: str) -> str:
    """ライブラリにパスワードロックを設定する。
    パスワードは CLI の stdin 経由で渡し、argv には一切露出しない（セキュア）。"""
    cli.lock_set(library, password)
    return f"lock set for library {library!r}"


@mcp.tool()
def stacknest_lock_clear(library: str) -> str:
    """ライブラリのパスワードロックを解除する。"""
    cli.lock_clear(library)
    return f"lock cleared for library {library!r}"


# --- インポート設定（import-config）---

@mcp.tool()
def stacknest_import_config_get(library: str) -> Any:
    """ライブラリのインポート設定（自動分類・厚み検出・プリセット等）を取得する。"""
    return cli.import_config_get(library)


@mcp.tool()
def stacknest_import_config_set(library: str,
                                auto_classify: bool | None = None,
                                thick: int | None = None,
                                preset: str | None = None) -> str:
    """ライブラリのインポート設定を更新する。
    auto_classify: 自動ジャンル分類 ON/OFF。thick: 厚み検出閾値（ページ数）。preset: デフォルトプリセット名。"""
    cli.import_config_set(library, auto_classify=auto_classify, thick=thick, preset=preset)
    return f"import config updated for library {library!r}"


@mcp.tool()
def stacknest_import_config_global_get() -> Any:
    """グローバルインポート設定を取得する（全ライブラリ共通のデフォルト）。"""
    return cli.import_config_global_get()


@mcp.tool()
def stacknest_import_config_global_set(auto_classify: bool | None = None,
                                       thick: int | None = None,
                                       preset: str | None = None) -> str:
    """グローバルインポート設定を更新する。"""
    cli.import_config_global_set(auto_classify=auto_classify, thick=thick, preset=preset)
    return "global import config updated"


# --- リンク修復（relink）---

@mcp.tool()
def stacknest_relink(library: str, id: int, new_path: str) -> str:
    """本のファイルパスを新しいパスに更新する（ファイル移動後のリンク修復）。
    id は stacknest_list で取得した本の id。new_path は移動後の絶対パス。"""
    cli.relink(library, id, new_path)
    return f"relinked book {id} to {new_path!r}"


# --- 重複検出（dedup）---

@mcp.tool()
def stacknest_dedup_scan(library: str, query: str | None = None) -> Any:
    """ライブラリ内の重複候補を検出してリストを返す。
    query で検索範囲を絞り込める。返り値の groups 配列の各要素が重複セット。"""
    return cli.dedup_scan(library, query=query)


if __name__ == "__main__":
    mcp.run()
