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
def stacknest_list(library: str, query: str | None = None, limit: int | None = None,
                   sort: str | None = None, order: str | None = None,
                   scope: str | None = None, scope_id: int | None = None,
                   recent_days: int | None = None, fields: str | None = None,
                   filter_json: dict | None = None, browse_json: list | None = None,
                   library_token: str | None = None) -> Any:
    """ライブラリの書籍一覧を返す（items に各本の id とメタ、total に総数）。
    library はライブラリ名または UUID（stacknest_libraries で確認）。query で検索、limit で件数（最大500）。
    sort/order/scope/filter_json/browse_json/fields で絞り込み・並び替え。
    library_token はロック庫の解錠トークン（stacknest_unlock で取得・省略時はセッションキャッシュを自動使用）。"""
    return cli.list_books(library, query=query, limit=limit, sort=sort, order=order,
                          scope=scope, scope_id=scope_id, recent_days=recent_days,
                          fields=fields, filter_json=filter_json, browse_json=browse_json,
                          library_token=library_token)


@mcp.tool()
def stacknest_add(library: str, paths: list[str], preset: str | None = None,
                  library_token: str | None = None) -> Any:
    """サーバローカルのファイル/フォルダパスを本としてライブラリに追加する（in-place・移動しない）。
    返り値の addedIDs が追加された本の id。alreadyPresent は既登録、failed は失敗パス。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.add(library, paths, preset=preset, library_token=library_token)


@mcp.tool()
def stacknest_set(library: str, id: int, title: str | None = None, author: str | None = None,
                  series: str | None = None, volume: int | None = None, genre: str | None = None,
                  keyword_a: str | None = None, keyword_b: str | None = None,
                  memo: str | None = None, neta: str | None = None, rating: int | None = None,
                  unseen: bool | None = None, book_type: int | None = None,
                  direction: str | None = None, library_token: str | None = None) -> str:
    """書籍のメタデータを更新する（指定したフィールドのみ）。id は stacknest_list で取得する。
    unseen: 未読フラグ（true/false）。book_type: 本の種別（整数）。direction: 読み方向（ltr/rtl）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.set_meta(library, id, title=title, author=author, series=series, volume=volume,
                 genre=genre, keyword_a=keyword_a, keyword_b=keyword_b,
                 memo=memo, neta=neta, rating=rating,
                 unseen=unseen, book_type=book_type, direction=direction,
                 library_token=library_token)
    return f"updated book {id}"


@mcp.tool()
def stacknest_remove(library: str, ids: list[int], trash: bool = False,
                     library_token: str | None = None) -> str:
    """書籍をライブラリから削除する（破壊的）。既定は DB エントリのみ削除し実ファイルは残す。
    trash=True で実ファイルを macOS ゴミ箱へ移動（復元可）。id は stacknest_list で取得する。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.remove(library, ids, trash=trash, library_token=library_token)
    return f"removed {len(ids)} book(s)"


@mcp.tool()
def stacknest_detail(library: str, id: int, library_token: str | None = None) -> Any:
    """書籍 1 件の全メタデータを返す。id は stacknest_list で取得する。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.detail(library, id, library_token=library_token)


@mcp.tool()
def stacknest_facets(library: str, field: str, library_token: str | None = None) -> Any:
    """指定フィールド（author/genre 等）の distinct 値一覧を返す。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.facets(library, field, library_token=library_token)


@mcp.tool()
def stacknest_shelves(library: str, library_token: str | None = None) -> Any:
    """ライブラリの棚（スマート棚・手動棚）一覧を返す。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.shelves(library, library_token=library_token)


@mcp.tool()
def stacknest_me() -> Any:
    """接続トークンの権限情報（role/tier/scope）を返す。"""
    return cli.me()


# --- 棚（shelf）CRUD ---

@mcp.tool()
def stacknest_shelf_create(library: str, title: str,
                           smart: bool = False,
                           conditions: dict | None = None,
                           library_token: str | None = None) -> Any:
    """棚を作成する。smart=True でスマート棚（conditions で条件 JSON を渡す）、
    False で手動棚。返り値に新棚の id が含まれる。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.shelf_create(library, title, smart=smart, conditions=conditions,
                            library_token=library_token)


@mcp.tool()
def stacknest_shelf_delete(library: str, shelf_id: int, library_token: str | None = None) -> str:
    """棚を削除する（中身の本はライブラリに残る）。shelf_id は stacknest_shelves で取得。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.shelf_delete(library, shelf_id, library_token=library_token)
    return f"deleted shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_rename(library: str, shelf_id: int, title: str,
                           library_token: str | None = None) -> str:
    """棚をリネームする。library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.shelf_rename(library, shelf_id, title, library_token=library_token)
    return f"renamed shelf {shelf_id} to {title!r}"


@mcp.tool()
def stacknest_shelf_conditions_get(library: str, shelf_id: int,
                                   library_token: str | None = None) -> Any:
    """スマート棚の条件 JSON を取得する。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.shelf_conditions_get(library, shelf_id, library_token=library_token)


@mcp.tool()
def stacknest_shelf_conditions_set(library: str, shelf_id: int, conditions: dict,
                                   library_token: str | None = None) -> str:
    """スマート棚の条件 JSON を更新する。conditions は {"version":1,"match":"all","rules":[...]} 形式。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.shelf_conditions_set(library, shelf_id, conditions, library_token=library_token)
    return f"updated conditions for shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_add_books(library: str, shelf_id: int, ids: list[int],
                              library_token: str | None = None) -> str:
    """手動棚に本を追加する。ids は stacknest_list で取得した本の id リスト。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.shelf_add_books(library, shelf_id, ids, library_token=library_token)
    return f"added {len(ids)} book(s) to shelf {shelf_id}"


@mcp.tool()
def stacknest_shelf_remove_books(library: str, shelf_id: int, ids: list[int],
                                 library_token: str | None = None) -> str:
    """手動棚から本を除く（本自体はライブラリに残る）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.shelf_remove_books(library, shelf_id, ids, library_token=library_token)
    return f"removed {len(ids)} book(s) from shelf {shelf_id}"


# --- フォルダ監視（watch）---

@mcp.tool()
def stacknest_watch_get(library: str, library_token: str | None = None) -> Any:
    """ライブラリの自動監視フォルダ設定を取得する。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.watch_get(library, library_token=library_token)


@mcp.tool()
def stacknest_watch_set(library: str, config: dict, library_token: str | None = None) -> str:
    """ライブラリの自動監視フォルダ設定を更新する。
    config は {"folders":["/path/to/dir"],"preset":"standard"} 等の形式。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.watch_set(library, config, library_token=library_token)
    return "watch config updated"


# --- ロック（lock）---

@mcp.tool()
def stacknest_lock_set(library: str, password: str, library_token: str | None = None) -> str:
    """ライブラリにパスワードロックを設定する。
    パスワードは CLI の stdin 経由で渡し、argv には一切露出しない（セキュア）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.lock_set(library, password, library_token=library_token)
    return f"lock set for library {library!r}"


@mcp.tool()
def stacknest_lock_clear(library: str, library_token: str | None = None) -> str:
    """ライブラリのパスワードロックを解除する。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.lock_clear(library, library_token=library_token)
    return f"lock cleared for library {library!r}"


# --- インポート設定（import-config）---

@mcp.tool()
def stacknest_import_config_get(library: str, library_token: str | None = None) -> Any:
    """ライブラリのインポート設定（自動分類・厚み検出・プリセット等）を取得する。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.import_config_get(library, library_token=library_token)


@mcp.tool()
def stacknest_import_config_set(library: str,
                                auto_classify: bool | None = None,
                                thick: int | None = None,
                                library_token: str | None = None) -> str:
    """ライブラリのインポート設定 override を更新する（指定分のみ）。
    auto_classify: 自動ジャンル分類 ON/OFF。thick: 厚み検出閾値（ページ数）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.import_config_set(library, auto_classify=auto_classify, thick=thick,
                          library_token=library_token)
    return f"import config updated for library {library!r}"


@mcp.tool()
def stacknest_import_config_global_get() -> Any:
    """グローバルインポート設定を取得する（全ライブラリ共通のデフォルト）。"""
    return cli.import_config_global_get()


@mcp.tool()
def stacknest_import_config_global_set(auto_classify: bool, thick: int) -> str:
    """グローバルインポート設定を更新する（両値必須・全ライブラリ共通の既定・admin）。"""
    cli.import_config_global_set(auto_classify, thick)
    return "global import config updated"


# --- リンク修復（relink）---

@mcp.tool()
def stacknest_relink(library: str, id: int, new_path: str,
                     library_token: str | None = None) -> str:
    """本のファイルパスを新しいパスに更新する（ファイル移動後のリンク修復）。
    id は stacknest_list で取得した本の id。new_path は移動後の絶対パス。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.relink(library, id, new_path, library_token=library_token)
    return f"relinked book {id} to {new_path!r}"


# --- 重複検出（dedup）---

@mcp.tool()
def stacknest_dedup_scan(library: str, library_token: str | None = None) -> Any:
    """ライブラリ内の重複候補を検出して結果を返す（exact/possible グループ＋統計）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.dedup_scan(library, library_token=library_token)


# --- ロック解錠（unlock）---

@mcp.tool()
def stacknest_unlock(library: str, password: str) -> Any:
    """ロック庫を解錠し短命ライブラリトークンを返す（{"libraryToken": ...}）。
    パスワードは CLI の stdin 経由で渡し argv には残さない。
    解錠後はトークン/パスワードがセッションにキャッシュされ、以後のツールは library_token 省略で
    自動的にこの庫へアクセスできる（トークン失効時は自動で再解錠）。"""
    return cli.unlock(library, password)


# --- グラント CRUD（admin）---

@mcp.tool()
def stacknest_grant_list() -> Any:
    """アクセスグラント一覧を返す（id/label/tier/scope/token）。admin 接続が必要。"""
    return cli.grant_list()


@mcp.tool()
def stacknest_grant_create(label: str, tier: str, scope: dict | None = None) -> Any:
    """グラントを作成し token を含む結果を返す。tier は read/edit/admin。
    scope は {"libraries":["uuid",...]} で対象限定、省略で全ライブラリ。admin 必須。"""
    return cli.grant_create(label, tier, scope=scope)


@mcp.tool()
def stacknest_grant_update(grant_id: str, label: str | None = None,
                           tier: str | None = None, scope: dict | None = None) -> Any:
    """グラントを更新する（指定分のみ）。admin 必須。"""
    return cli.grant_update(grant_id, label=label, tier=tier, scope=scope)


@mcp.tool()
def stacknest_grant_delete(grant_id: str) -> str:
    """グラントを削除する。admin 必須。"""
    cli.grant_delete(grant_id)
    return f"deleted grant {grant_id}"


# --- 一括スタンプ / ラベルカスタマイズ ---

@mcp.tool()
def stacknest_stamp_apply(library: str, field: str, book_ids: list[int],
                          value: str | None = None, clear: bool = False,
                          library_token: str | None = None) -> Any:
    """複数の本に値を一括スタンプ（追記）またはクリアする。value か clear のいずれか。
    field は対象カラム（genre/keyword_a 等）。edit 権限が必要。"""
    return cli.stamp_apply(library, field, book_ids, value=value, clear=clear,
                           library_token=library_token)


@mcp.tool()
def stacknest_stamp_definitions_get(library: str, library_token: str | None = None) -> Any:
    """スタンプ定義（dbColumn→候補値）を取得する。"""
    return cli.stamp_definitions_get(library, library_token=library_token)


@mcp.tool()
def stacknest_stamp_definitions_set(library: str, definitions: dict,
                                    library_token: str | None = None) -> Any:
    """スタンプ定義を全置換する。definitions は {"genre":["..."],...}。edit 必須。"""
    return cli.stamp_definitions_set(library, definitions, library_token=library_token)


@mcp.tool()
def stacknest_label_get(library: str, library_token: str | None = None) -> Any:
    """ラベルカスタマイズ（customFieldLabels/customBookTypeLabels）を取得する。"""
    return cli.label_get(library, library_token=library_token)


@mcp.tool()
def stacknest_label_set(library: str, settings: dict, library_token: str | None = None) -> Any:
    """ラベルカスタマイズを更新する。settings は {"customFieldLabels":{...},"customBookTypeLabels":{...}}。edit 必須。"""
    return cli.label_set(library, settings, library_token=library_token)


if __name__ == "__main__":
    mcp.run()
