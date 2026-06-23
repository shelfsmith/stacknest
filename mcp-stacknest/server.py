# SPDX-License-Identifier: MIT
"""StackNest MCP サーバ。stacknest CLI をラップして MCP ツールとして公開する。
接続は CLI が同一 Mac の UserDefaults から自動検出（StackNest 起動＋ローカル自動化 ON が前提）。"""
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
                  memo: str | None = None, neta: str | None = None, rating: int | None = None) -> str:
    """書籍のメタデータを更新する（指定したフィールドのみ）。id は stacknest_list で取得する。"""
    cli.set_meta(library, id, title=title, author=author, series=series, volume=volume,
                 genre=genre, keyword_a=keyword_a, keyword_b=keyword_b,
                 memo=memo, neta=neta, rating=rating)
    return f"updated book {id}"


@mcp.tool()
def stacknest_remove(library: str, ids: list[int], trash: bool = False) -> str:
    """書籍をライブラリから削除する（破壊的）。既定は DB エントリのみ削除し実ファイルは残す。
    trash=True で実ファイルを macOS ゴミ箱へ移動（復元可）。id は stacknest_list で取得する。"""
    cli.remove(library, ids, trash=trash)
    return f"removed {len(ids)} book(s)"


if __name__ == "__main__":
    mcp.run()
