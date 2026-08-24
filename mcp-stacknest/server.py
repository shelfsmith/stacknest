# SPDX-License-Identifier: MIT
"""StackNest MCP サーバ。stacknest CLI をラップして MCP ツールとして公開する。
接続は CLI が同一 Mac の UserDefaults から自動検出（StackNest 起動＋ローカルアクセス ON が前提）。"""
from __future__ import annotations

import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cli  # noqa: E402

from mcp.server.mcpserver import MCPServer  # noqa: E402

mcp = MCPServer("stacknest")


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
    config は WatchConfigDTO 形式: {"enabled": true, "folders": [...]}。
    folders: [{"id": "...", "path": "/abs/path", "enabled": true,
               "presetID": null, "baseline": [],
               "subfolderMode": "topLevelOnly" | "archive" | "recurse"}]
      subfolderMode: topLevelOnly=サブフォルダを取り込まない（直下ファイルのみ）／
                     archive=直下サブフォルダを各1冊として取込（孫には降りない）＋直下の素ファイルも個別取込／
                     recurse=サブフォルダを再帰走査し中のファイルを個別取込。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.watch_set(library, config, library_token=library_token)
    return "watch config updated"


# --- ロック（lock）---

@mcp.tool()
def stacknest_lock_set(library: str, password: str, current_password: str | None = None,
                       library_token: str | None = None) -> str:
    """ライブラリにパスワードロックを設定・変更する。
    既存ロックがある場合、current_password（現在のパスワード）が必須 — 誤り/未指定は拒否され、
    ロックは変更されない。ロックが無い場合（新規設定）は current_password 不要。
    パスワードは CLI の stdin 経由で渡し、argv には一切露出しない（セキュア）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.lock_set(library, password, current_password=current_password, library_token=library_token)
    return f"lock set for library {library!r}"


@mcp.tool()
def stacknest_lock_clear(library: str, current_password: str | None = None,
                         library_token: str | None = None) -> str:
    """ライブラリのパスワードロックを解除する。
    既存ロックがある場合、current_password（現在のパスワード）が必須 — 誤り/未指定は拒否される。
    パスワードは CLI の stdin 経由で渡し、argv には一切露出しない（セキュア）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    cli.lock_clear(library, current_password=current_password, library_token=library_token)
    return f"lock cleared for library {library!r}"


# --- Finder タグ同期（finder-tags）---

@mcp.tool()
def stacknest_finder_tags_status(library: str, library_token: str | None = None) -> Any:
    """Finder タグ同期の状態を返す（field=同期対象の列名/None、running=走行中か、locked=施錠中か）。
    アプリで開いている庫にしか使えない（開いていなければエラー）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.finder_tags_status(library, library_token=library_token)


@mcp.tool()
def stacknest_finder_tags_set(library: str, field: str | None = None,
                              library_token: str | None = None) -> Any:
    """Finder タグと同期する項目を変える。
    field は genre / series / author / neta / keyword_a / keyword_b / keyword_c のいずれか、
    または None・"none"（同期しない）。知らない列名はエラーになる。
    ★ 項目を変えると前回同期値が全消しされる（設計上の安全策・元に戻せない）。
    ★ この機能は Finder タグとして庫のメタデータをファイルに書き出す。捨ててよい庫で使うこと。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.finder_tags_set(library, field, library_token=library_token)


@mcp.tool()
def stacknest_finder_tags_resync(library: str, library_token: str | None = None) -> Any:
    """Finder タグを今すぐ再照合し、終わるまで待って結果を返す。
    アプリのメニュー「Finder タグを再照合」と全く同じ経路を通る（施錠中は走らない）。
    返り値の status は started / noField / locked / alreadyRunning / noLibrary。
    started 以外のとき件数はすべて 0（「変化なし」と「断られた」を件数で区別しないこと）。
    updatedInLibrary=Finder→庫、updatedInFinder=庫→Finder、
    skippedTags=区切り文字「, 」を含むため同期しなかったタグ、
    indexingDisabledVolumes=Spotlight 索引が無効なボリューム（空でなければ Finder→庫は動いていない）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.finder_tags_resync(library, library_token=library_token)


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


# --- 整合性検査（integrity・G27a）---

@mcp.tool()
def stacknest_integrity_scan(library: str, library_token: str | None = None) -> Any:
    """pages 未取得の本を開いて分類する簡易チェックを実行し、件数の内訳を返す。
    結果は DB に永続化されるので、以後 stacknest_integrity_status / _list で
    再スキャンなしに何度でも参照できる。"""
    return cli.integrity_scan(library, library_token=library_token)


@mcp.tool()
def stacknest_integrity_status(library: str, library_token: str | None = None) -> Any:
    """整合性検査の集計を返す（checked / unchecked / damaged / degraded）。
    degraded は前回 ok が今回 damaged になった本＝ディスク上で劣化した疑い。"""
    return cli.integrity_status(library, library_token=library_token)


@mcp.tool()
def stacknest_integrity_list(library: str, status: str = "damaged",
                             library_token: str | None = None) -> Any:
    """指定した状態の本を一覧する（ok / damaged / empty / missing / unsupported）。"""
    return cli.integrity_list(library, status=status, library_token=library_token)


# --- フル CRC スキャン（非同期ジョブ・G27b）---

@mcp.tool()
def stacknest_integrity_full_scan(library: str, mode: str = "unchecked",
                                  library_token: str | None = None) -> str:
    """全冊 CRC 検証をバックグラウンドジョブとして開始する（stacknest_integrity_scan の
    簡易チェックと違い、アーカイブ全エントリの CRC を検証する詳細版）。
    実測値: 約 4.5 秒/冊 ―― 蔵書規模によっては数十時間かかる（例: 22,880 冊で約 31 時間）。
    **このツールは起動（または「既に実行中」）を確認したらすぐ返り、完走は待たない。**
    進捗は stacknest_integrity_job_status で確認し、必要なら stacknest_integrity_cancel で中断する。
    mode: "unchecked"（既定・未検査のみ）/ "all"（全件を再検査。ビット腐敗検出に必要）/
    "damaged"（前回 damaged だった本のみ再検査。修復後の確認向け）。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.integrity_full_scan(library, mode=mode, library_token=library_token)


@mcp.tool()
def stacknest_integrity_job_status(library: str, library_token: str | None = None) -> Any:
    """実行中のメンテナンスジョブ（full-scan・complete-metadata・compress-covers 等）の
    進捗を返す。running/job/done/total/startedAt を含み、実行中でなければ running=false のみ。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.integrity_job_status(library, library_token=library_token)


@mcp.tool()
def stacknest_integrity_cancel(library: str, library_token: str | None = None) -> str:
    """実行中のメンテナンスジョブ（full-scan 含む）を中断する。実行中ジョブが無ければ no-op。
    library_token は省略時キャッシュ自動使用のロック庫解錠トークン。"""
    return cli.integrity_cancel(library, library_token=library_token)


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


# --- ライブラリ開閉（ローカル制御専用・G27b Task7）---

@mcp.tool()
def stacknest_library_open(path: str) -> Any:
    """パスを指定してライブラリウィンドウを開く（ウィンドウが無いライブラリを headless で操作可能にする）。
    既にそのパスが開いていれば新規ウィンドウは開かず、既存の uuid をそのまま返す。
    施錠庫でも開ける（解錠画面が表示された状態で開く。以後の操作には stacknest_unlock が必要）。
    存在しない/非対応パスはエラーになる。
    **ローカル制御専用** ―― StackNest 起動中の同一 Mac からのみ動作し、共有サーバ経由では使えない。"""
    return cli.library_open(path)


@mcp.tool()
def stacknest_library_close(uuid: str) -> str:
    """uuid を指定してライブラリウィンドウを閉じる。uuid は stacknest_libraries や
    stacknest_library_open の戻り値で確認する。
    **ローカル制御専用** ―― StackNest 起動中の同一 Mac からのみ動作し、共有サーバ経由では使えない。"""
    cli.library_close(uuid)
    return f"closed library {uuid}"


if __name__ == "__main__":
    mcp.run()
