# SPDX-License-Identifier: MIT
"""stacknest CLI を subprocess で呼ぶ薄いラッパ（接続検出/認証/操作は CLI に委譲）。"""
from __future__ import annotations

import json
import os
import subprocess
from typing import Any

# set のフィールド名（snake_case）→ CLI フラグは keyword_a → --keyword-a 変換
_SET_FIELDS = ("title", "author", "series", "volume", "genre",
               "keyword_a", "keyword_b", "memo", "neta", "rating")


class StacknestError(Exception):
    """CLI 非0終了 / バイナリ不在 / タイムアウト。"""
    def __init__(self, exit_code: int, stderr: str):
        self.exit_code = exit_code
        self.stderr = stderr
        super().__init__(f"stacknest CLI error (exit {exit_code}): {stderr.strip()}")


def _read_default_cli_path() -> str | None:
    """アプリが記録した同梱 CLI パスを macOS defaults から読む（未記録/失敗は None）。"""
    try:
        proc = subprocess.run(
            ["defaults", "read", "app.shelfsmith.stacknest", "cli_path"],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        # OSError は FileNotFoundError/PermissionError 等を包含。defaults 不在/実行不可でも
        # 静かに PATH フォールバックさせ、全 MCP ツールがクラッシュしないようにする。
        return None
    out = proc.stdout.strip()
    return out if (proc.returncode == 0 and out) else None


def cli_path() -> str:
    # env 明示 > アプリ記録(defaults cli_path) > PATH の stacknest-cli
    env = os.environ.get("STACKNEST_CLI")
    if env:
        return env
    return _read_default_cli_path() or "stacknest-cli"


def _opt(flag: str, value: Any) -> list[str]:
    return [] if value is None else [flag, str(value)]


def build_argv(subcommand: str, *, library: str | None = None, query: str | None = None,
               limit: int | None = None, preset: str | None = None, trash: bool = False,
               paths: list[str] | None = None, ids: list[int] | None = None,
               book_id: int | None = None, field: str | None = None,
               fields: dict[str, Any] | None = None,
               json_output: bool = True) -> list[str]:
    argv: list[str] = [subcommand]
    argv += _opt("--library", library)
    argv += _opt("--query", query)
    argv += _opt("--limit", limit)
    argv += _opt("--preset", preset)
    if fields:
        for key in _SET_FIELDS:
            val = fields.get(key)
            if val is not None:
                argv += [f"--{key.replace('_', '-')}", str(val)]
        # set 拡張フィールド: unseen(bool)/book_type(int)/direction(str)
        if "unseen" in fields and fields["unseen"] is not None:
            argv += ["--unseen", "true" if fields["unseen"] else "false"]
        if "book_type" in fields and fields["book_type"] is not None:
            argv += ["--book-type", str(fields["book_type"])]
        if "direction" in fields and fields["direction"] is not None:
            argv += ["--direction", str(fields["direction"])]
    if trash:
        argv.append("--trash")
    if json_output:
        argv.append("--json")
    # 位置引数は `--`（オプション終端）の後ろに置く。`--trash` のような値の path/id を
    # CLI がフラグと誤解釈する argv フラグ・スマグリングを防ぐ（Swift ArgumentParser は `--` 対応）。
    positionals: list[str] = []
    if book_id is not None:
        positionals.append(str(book_id))
    if field is not None:
        positionals.append(field)
    if paths:
        positionals += [str(p) for p in paths]
    if ids:
        positionals += [str(i) for i in ids]
    if positionals:
        argv.append("--")
        argv += positionals
    return argv


def _exec(argv: list[str], *, timeout: int = 60) -> subprocess.CompletedProcess:
    """subprocess 実行（バイナリ不在/タイムアウトは StacknestError へ）。非0でも raise しない。"""
    cli = cli_path()
    try:
        return subprocess.run([cli, *argv], capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise StacknestError(127, f"stacknest CLI が見つかりません: {cli}（環境変数 STACKNEST_CLI を確認）")
    except subprocess.TimeoutExpired:
        raise StacknestError(124, f"stacknest CLI がタイムアウトしました（{timeout}s）")


def run(argv: list[str], *, timeout: int = 60) -> str:
    proc = _exec(argv, timeout=timeout)
    if proc.returncode != 0:
        raise StacknestError(proc.returncode, proc.stderr or proc.stdout)
    return proc.stdout


# --- 高レベル操作（CLI 1:1） ---

def libraries() -> Any:
    return json.loads(run(build_argv("libraries")))


def list_books(library: str, query: str | None = None, limit: int | None = None) -> Any:
    return json.loads(run(build_argv("list", library=library, query=query, limit=limit)))


def add(library: str, paths: list[str], preset: str | None = None) -> Any:
    # CLI add は failed が1件でもあると exit 1（reply JSON は stdout）。部分成功も
    # 構造化結果（addedIDs/alreadyPresent/failed）として返し、LLM が成否を正しく扱えるようにする。
    # 接続/認証など exit>=2、または stdout が解釈不能のときだけ例外にする。
    proc = _exec(build_argv("add", library=library, paths=paths, preset=preset))
    if proc.returncode in (0, 1) and proc.stdout.strip():
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            pass
    if proc.returncode != 0:
        raise StacknestError(proc.returncode, proc.stderr or proc.stdout)
    return {}


def set_meta(library: str, book_id: int, **fields: Any) -> None:
    run(build_argv("set", library=library, book_id=book_id, fields=fields))


def remove(library: str, ids: list[int], trash: bool = False) -> None:
    run(build_argv("rm", library=library, ids=ids, trash=trash))


def detail(library: str, book_id: int) -> Any:
    return json.loads(run(build_argv("detail", library=library, book_id=book_id)))


def facets(library: str, field: str) -> Any:
    return json.loads(run(build_argv("facets", library=library, field=field)))


def shelves(library: str) -> Any:
    return json.loads(run(build_argv("shelves", library=library)))


def me() -> Any:
    return json.loads(run(build_argv("me")))
