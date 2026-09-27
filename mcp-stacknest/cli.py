# SPDX-License-Identifier: MIT
"""Thin wrapper that calls the stacknest CLI via subprocess (connection detection/auth/operations are delegated to the CLI)."""
from __future__ import annotations

import json
import os
import subprocess
from typing import Any

# set のフィールド名（snake_case）→ CLI フラグは keyword_a → --keyword-a 変換
_SET_FIELDS = ("title", "author", "series", "volume", "genre",
               "keyword_a", "keyword_b", "memo", "neta", "rating")


class StacknestError(Exception):
    """The CLI exited non-zero / the binary is missing / it timed out."""
    def __init__(self, exit_code: int, stderr: str):
        self.exit_code = exit_code
        self.stderr = stderr
        super().__init__(f"stacknest CLI error (exit {exit_code}): {stderr.strip()}")


def _read_default_cli_path() -> str | None:
    """Read the bundled CLI path the app recorded, from macOS defaults (None if unset or it fails)."""
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
               text: str | None = None,
               fields: dict[str, Any] | None = None,
               json_output: bool = True,
               sub: str | None = None,
               flags: dict[str, Any] | None = None,
               smart: bool = False) -> list[str]:
    argv: list[str] = [subcommand]
    if sub is not None:
        argv.append(sub)
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
    # flags: bool True → 値なしフラグ（--k）、bool False → スキップ、その他 → --k str(v)
    if flags:
        for k, v in flags.items():
            if v is None:
                continue
            elif isinstance(v, bool):
                if v:
                    argv.append(f"--{k}")
                # False → skip
            else:
                argv += [f"--{k}", str(v)]
    if trash:
        argv.append("--trash")
    if smart:
        argv.append("--smart")
    if json_output:
        argv.append("--json")
    # 位置引数は `--`（オプション終端）の後ろに置く。`--trash` のような値の path/id を
    # CLI がフラグと誤解釈する argv フラグ・スマグリングを防ぐ（Swift ArgumentParser は `--` 対応）。
    positionals: list[str] = []
    if book_id is not None:
        positionals.append(str(book_id))
    if field is not None:
        positionals.append(field)
    if text is not None:
        positionals.append(text)
    if ids:
        positionals += [str(i) for i in ids]
    if paths:
        positionals += [str(p) for p in paths]
    if positionals:
        argv.append("--")
        argv += positionals
    return argv


def _exec(argv: list[str], *, timeout: int = 60, input: str | None = None,
          library_token: str | None = None) -> subprocess.CompletedProcess:
    """Run the subprocess (a missing binary or a timeout becomes a StacknestError). Does not raise on a non-zero exit.
    When library_token is given, it's injected into the env as STACKNEST_LIBRARY_TOKEN (never in argv, so it stays out of shell history)."""
    cli = cli_path()
    env = None
    if library_token:
        env = dict(os.environ)
        env["STACKNEST_LIBRARY_TOKEN"] = library_token
    try:
        return subprocess.run(
            [cli, *argv], capture_output=True, text=True, timeout=timeout, input=input, env=env)
    except FileNotFoundError:
        raise StacknestError(127, f"stacknest CLI not found: {cli} (check the STACKNEST_CLI environment variable)")
    except subprocess.TimeoutExpired:
        raise StacknestError(124, f"stacknest CLI timed out ({timeout}s)")


def run(argv: list[str], *, timeout: int = 60, input: str | None = None,
        library_token: str | None = None) -> str:
    proc = _exec(argv, timeout=timeout, input=input, library_token=library_token)
    if proc.returncode != 0:
        raise StacknestError(proc.returncode, proc.stderr or proc.stdout)
    return proc.stdout


# --- ロック庫トークンのセッションキャッシュ（MCP サーバプロセス生存期間のみ・永続化しない） ---
# spec §2.1: STACKNEST_LIBRARY_TOKEN が stale(TTL/再起動で失効) になったら自動で再 unlock し、
# 新トークンを書き戻して処理を継続する。再 unlock には password が要るため、unlock 実行時に
# password も（セッション中のみ）保持する。
_library_tokens: dict[str, str] = {}      # library -> 現在の libraryToken
_library_passwords: dict[str, str] = {}   # library -> unlock 用 password
_LOCKED_EXIT_CODE = 3                      # CLI が 403(locked/stale) を返す専用 exit code


def _with_library(library: str | None, explicit_token: str | None, call):
    """Wrapper for operations that target a library.
    - Uses explicit_token if given; otherwise the cached token (None if neither is set).
    - On a failure with exit 3 (locked/stale), if that library's password is cached,
      automatically re-unlocks -> caches the new token and writes it back (STACKNEST_LIBRARY_TOKEN) -> retries once.
    - If no password is cached (e.g. an externally obtained token was passed directly), does not auto-refresh and raises instead.
    call is a callable (token: str | None) -> str (run()'s stdout)."""
    token = explicit_token or (_library_tokens.get(library) if library else None)
    try:
        return call(token)
    except StacknestError as e:
        if e.exit_code != _LOCKED_EXIT_CODE or not library:
            raise
        password = _library_passwords.get(library)
        if not password:
            raise StacknestError(
                e.exit_code,
                (e.stderr or "") + "\n(If this is a locked library, unlock it again with stacknest_unlock. It could also be insufficient permissions (tier).)")
        unlock(library, password)                 # re-unlock (caches and writes back STACKNEST_LIBRARY_TOKEN)
        return call(_library_tokens[library])     # retry once with the new token


# --- 高レベル操作（CLI 1:1） ---

def libraries() -> Any:
    return json.loads(run(build_argv("libraries")))


def list_books(library: str, query: str | None = None, limit: int | None = None, *,
               sort: str | None = None, order: str | None = None,
               scope: str | None = None, scope_id: int | None = None,
               recent_days: int | None = None, fields: str | None = None,
               filter_json: dict | None = None, browse_json: list | None = None,
               library_token: str | None = None) -> Any:
    flags: dict[str, Any] = {}
    if sort is not None:
        flags["sort"] = sort
    if order is not None:
        flags["order"] = order
    if scope is not None:
        flags["scope"] = scope
    if scope_id is not None:
        flags["scope-id"] = scope_id
    if recent_days is not None:
        flags["recent-days"] = recent_days
    if fields is not None:
        flags["fields"] = fields
    if filter_json is not None:
        flags["filter-json"] = json.dumps(filter_json)
    if browse_json is not None:
        flags["browse-json"] = json.dumps(browse_json)
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("list", library=library, query=query, limit=limit, flags=flags),
                        library_token=tok)))


def add(library: str, paths: list[str], preset: str | None = None,
        *, library_token: str | None = None) -> Any:
    # CLI add は failed が1件でもあると exit 1（reply JSON は stdout）。部分成功も
    # 構造化結果（addedIDs/alreadyPresent/failed）として返し、LLM が成否を正しく扱えるようにする。
    # 接続/認証など exit>=2、または stdout が解釈不能のときだけ例外にする。
    # exit 3（locked/stale）は _with_library が拾って自動再 unlock＋リトライする。
    def _do(tok: str | None) -> str:
        proc = _exec(build_argv("add", library=library, paths=paths, preset=preset), library_token=tok)
        if proc.returncode in (0, 1) and proc.stdout.strip():
            return proc.stdout                      # 部分成功(1)含め reply JSON を返す
        if proc.returncode == 0:
            return "{}"                             # 成功だが空 stdout（旧挙動を維持）
        raise StacknestError(proc.returncode, proc.stderr or proc.stdout)  # exit 3 等は _with_library が拾う
    out = _with_library(library, library_token, _do)
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {}


def set_meta(library: str, book_id: int, *, library_token: str | None = None, **fields: Any) -> None:
    _with_library(library, library_token,
        lambda tok: run(build_argv("set", library=library, book_id=book_id, fields=fields), library_token=tok))


def remove(library: str, ids: list[int], trash: bool = False, *, library_token: str | None = None) -> None:
    _with_library(library, library_token,
        lambda tok: run(build_argv("rm", library=library, ids=ids, trash=trash), library_token=tok))


def detail(library: str, book_id: int, *, library_token: str | None = None) -> Any:
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("detail", library=library, book_id=book_id), library_token=tok)))


def facets(library: str, field: str, *, library_token: str | None = None) -> Any:
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("facets", library=library, field=field), library_token=tok)))


def shelves(library: str, *, library_token: str | None = None) -> Any:
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("shelves", library=library), library_token=tok)))


def me() -> Any:
    return json.loads(run(build_argv("me")))


def unlock(library: str, password: str) -> Any:
    """Unlock a locked library and return {"libraryToken": ...} (the password is passed via stdin, never in argv).
    On success, caches the token/password for the session and writes back STACKNEST_LIBRARY_TOKEN (spec §2.1)."""
    out = run(build_argv("unlock", library=library, flags={"password-stdin": True}),
              input=password)
    reply = json.loads(out)
    token = reply.get("libraryToken")
    if token:
        _library_tokens[library] = token
        _library_passwords[library] = password
        os.environ["STACKNEST_LIBRARY_TOKEN"] = token
    return reply


# --- Shelf CRUD ---

def shelf_create(library: str, title: str, *,
                 smart: bool = False, conditions: dict | None = None,
                 library_token: str | None = None) -> Any:
    """Create a shelf. smart=True makes a smart shelf; pass its condition JSON via conditions."""
    flags: dict[str, Any] = {"title": title}
    if conditions is not None:
        flags["conditions-json"] = json.dumps(conditions)
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="create", library=library, flags=flags, smart=smart),
                        library_token=tok)))


def shelf_delete(library: str, shelf_id: int, *, library_token: str | None = None) -> None:
    """Delete a shelf."""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="rm", library=library,
                                   book_id=shelf_id, json_output=False), library_token=tok))


def shelf_rename(library: str, shelf_id: int, title: str, *, library_token: str | None = None) -> None:
    """Rename a shelf."""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="rename", library=library, book_id=shelf_id,
                                   flags={"title": title}, json_output=False), library_token=tok))


def shelf_conditions_get(library: str, shelf_id: int, *, library_token: str | None = None) -> Any:
    """Get a smart shelf's condition JSON."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="conditions-get", library=library, book_id=shelf_id),
                        library_token=tok)))


def shelf_conditions_set(library: str, shelf_id: int, conditions: dict, *,
                         library_token: str | None = None) -> None:
    """Update a smart shelf's condition JSON."""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="conditions-set", library=library, book_id=shelf_id,
                                   flags={"conditions-json": json.dumps(conditions)}, json_output=False),
                        library_token=tok))


def shelf_add_books(library: str, shelf_id: int, ids: list[int], *,
                    library_token: str | None = None) -> None:
    """Add books to a manual shelf."""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="add-books", library=library,
                                   book_id=shelf_id, ids=ids, json_output=False), library_token=tok))


def shelf_remove_books(library: str, shelf_id: int, ids: list[int], *,
                       library_token: str | None = None) -> None:
    """Remove books from a manual shelf."""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="remove-books", library=library,
                                   book_id=shelf_id, ids=ids, json_output=False), library_token=tok))


# --- Watched folders ---

def watch_get(library: str, *, library_token: str | None = None) -> Any:
    """Get the library's watch settings."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("watch", sub="get", library=library), library_token=tok)))


def watch_set(library: str, config: dict, *, library_token: str | None = None) -> None:
    """Update the library's watch settings."""
    _with_library(library, library_token,
        lambda tok: run(build_argv("watch", sub="set", library=library,
                                   flags={"config-json": json.dumps(config)}, json_output=False),
                        library_token=tok))


# --- Lock ---

def lock_set(library: str, password: str, *, current_password: str | None = None,
            library_token: str | None = None) -> None:
    """Set or change a library's password lock (the password is passed via stdin, never in argv).
    G27a Task6: changing an existing lock requires current_password (the server checks whether a hash already exists).
    current_password is not needed when setting a new lock. When passing both via stdin, send them to
    the CLI as two lines, "current password\\nnew password" (the convention for carrying both in one stdin payload)."""
    flags: dict[str, Any] = {"password-stdin": True}
    if current_password is not None:
        flags["current-password-stdin"] = True
        stdin_payload = f"{current_password}\n{password}"
    else:
        stdin_payload = password
    _with_library(library, library_token,
        lambda tok: run(build_argv("lock", sub="set", library=library, flags=flags, json_output=False),
                        input=stdin_payload, library_token=tok))


def lock_clear(library: str, *, current_password: str | None = None,
              library_token: str | None = None) -> None:
    """Remove a library's password lock.
    G27a Task6: current_password is required if the library has a lock (passed via stdin, never in argv)."""
    flags: dict[str, Any] = {}
    stdin_payload = None
    if current_password is not None:
        flags["current-password-stdin"] = True
        stdin_payload = current_password
    _with_library(library, library_token,
        lambda tok: run(build_argv("lock", sub="clear", library=library, flags=flags, json_output=False),
                        input=stdin_payload, library_token=tok))


# --- Import settings ---

def import_config_get(library: str, *, library_token: str | None = None) -> Any:
    """Get the library's import settings."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("import-config", sub="get", library=library), library_token=tok)))


def import_config_set(library: str, *,
                      auto_classify: bool | None = None,
                      thick: int | None = None,
                      prefer_epub_title: bool | None = None,
                      library_token: str | None = None) -> None:
    """Update the library's import setting overrides (only the fields given).
    auto_classify and prefer_epub_title are bool (sent to the CLI as the strings "true"/"false"); thick is an integer."""
    flags: dict[str, Any] = {}
    if auto_classify is not None:
        flags["auto-classify"] = "true" if auto_classify else "false"
    if thick is not None:
        flags["thick"] = thick
    # G54-S4 Task 7: 未指定 (None) は override 削除（= グローバル既定に委譲）。auto_classify と同じ形。
    if prefer_epub_title is not None:
        flags["prefer-epub-title"] = "true" if prefer_epub_title else "false"
    _with_library(library, library_token,
        lambda tok: run(build_argv("import-config", sub="set", library=library,
                                   flags=flags, json_output=False), library_token=tok))


def import_config_global_get() -> Any:
    """Get the global import settings."""
    return json.loads(run(build_argv("import-config-global", sub="get")))


def import_config_global_set(auto_classify: bool, thick: int, prefer_epub_title: bool) -> None:
    """Update the global import settings (all values required; the CLI treats them as mandatory options)."""
    flags: dict[str, Any] = {
        "auto-classify": "true" if auto_classify else "false",
        "thick": thick,
        "prefer-epub-title": "true" if prefer_epub_title else "false",
    }
    run(build_argv("import-config-global", sub="set", flags=flags, json_output=False))


# --- Relink ---

def relink(library: str, book_id: int, new_path: str, *, library_token: str | None = None) -> None:
    """Update a book's file path to a new location (repairs the link after a file was moved)."""
    _with_library(library, library_token,
        lambda tok: run(build_argv("relink", library=library, book_id=book_id,
                                   flags={"new-path": new_path}, json_output=False), library_token=tok))


# --- Duplicate detection ---

def dedup_scan(library: str, *, library_token: str | None = None) -> Any:
    """Scan the library for duplicate candidates and return the results."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("dedup", library=library), library_token=tok)))


# --- Integrity check (G27a) ---

def integrity_scan(library: str, *, library_token: str | None = None) -> Any:
    """Run the quick check: open books with no page count yet and classify them, then return the counts.

    Measured at about 65 candidates in ~4 minutes (~3.46s/book), which would reliably miss the default
    60s timeout, so this call alone is given a longer one (other calls' defaults are unchanged).
    Waiting on a single synchronous request is a known limitation -- an async job with polling is
    being considered for Phase G27b.
    """
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="scan"),
                        timeout=1800, library_token=tok)))


def integrity_status(library: str, *, library_token: str | None = None) -> Any:
    """Return integrity check totals (checked / unchecked / damaged / degraded)."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="status"), library_token=tok)))


def integrity_list(library: str, *, status: str = "damaged",
                   library_token: str | None = None) -> Any:
    """List books in the given state (ok / damaged / empty / missing / unsupported)."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="list",
                                   flags={"status": status}), library_token=tok)))


# --- Full CRC scan (background job, G27b Task5) ---
#
# Measured at 4.464 sec/book, about 31 hours at a scale of 22,880 books. Unlike integrity_scan
# (the quick check), the server side here only starts an async job, so no long timeout is needed here
# (the default 60s is fine -- by design the CLI itself returns as soon as it confirms the job started).

def integrity_full_scan(library: str, *, mode: str = "unchecked",
                        library_token: str | None = None) -> str:
    """Start a full CRC verification as a background job. Returns the CLI's guidance message
    (either that it started, or that one was already running) verbatim as a stdout string
    (not JSON -- the server response is a bare 202/409 with no body)."""
    return _with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="full-scan",
                                   flags={"mode": mode}), library_token=tok))


def integrity_job_status(library: str, *, library_token: str | None = None) -> Any:
    """Return the progress of the running maintenance job (full-scan, complete-metadata, compress-covers, etc. --
    they all share the same job registry). running/job/done/total/startedAt."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="job-status"),
                        library_token=tok)))


def integrity_cancel(library: str, *, library_token: str | None = None) -> str:
    """Cancel the running maintenance job (including full-scan); a no-op if none is running.
    There's no cancel command specific to full-scan (it shares the existing maintenance/cancel)."""
    return _with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="cancel"),
                        library_token=tok))


# --- Grant CRUD (admin) ---

def grant_list() -> Any:
    return json.loads(run(build_argv("grant", sub="list")))


def grant_create(label: str, tier: str, scope: dict | None = None) -> Any:
    flags: dict[str, Any] = {"label": label, "tier": tier}
    if scope is not None:
        flags["scope-json"] = json.dumps(scope)
    return json.loads(run(build_argv("grant", sub="create", flags=flags)))


def grant_update(grant_id: str, *, label: str | None = None,
                 tier: str | None = None, scope: dict | None = None) -> Any:
    flags: dict[str, Any] = {}
    if label is not None:
        flags["label"] = label
    if tier is not None:
        flags["tier"] = tier
    if scope is not None:
        flags["scope-json"] = json.dumps(scope)
    return json.loads(run(build_argv("grant", sub="update", flags=flags, json_output=False) + [grant_id]))


def grant_delete(grant_id: str) -> None:
    run(build_argv("grant", sub="rm", json_output=False) + [grant_id])


# --- Stamp / label (per-library) ---

def stamp_apply(library: str, field: str, book_ids: list[int], *,
                value: str | None = None, clear: bool = False,
                library_token: str | None = None) -> Any:
    flags: dict[str, Any] = {"field": field}
    if value is not None:
        flags["value"] = value
    if clear:
        flags["clear"] = True
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("stamp", library=library, flags=flags, ids=book_ids), library_token=tok)))


def stamp_definitions_get(library: str, *, library_token: str | None = None) -> Any:
    # The server/CLI exchange StampDefinitionsDTO {"definitions": {col:[...]}}, but the MCP tool
    # deals with the inner map {col:[...]} directly (symmetric with set, same as label).
    raw = json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("stamp-definitions", sub="get", library=library), library_token=tok)))
    return raw.get("definitions", raw) if isinstance(raw, dict) else raw


def stamp_definitions_set(library: str, definitions: dict, *,
                          library_token: str | None = None) -> Any:
    # Wrap the inner map {col:[...]} into StampDefinitionsDTO {"definitions": {...}} before sending
    # (the CLI/server require the DTO shape; the bare inner map alone yields keyNotFound("definitions")).
    payload = json.dumps({"definitions": definitions})
    raw = json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("stamp-definitions", sub="set", library=library,
                                   flags={"definitions-json": payload}), library_token=tok)))
    return raw.get("definitions", raw) if isinstance(raw, dict) else raw


def label_get(library: str, *, library_token: str | None = None) -> Any:
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("label", sub="get", library=library), library_token=tok)))


def label_set(library: str, settings: dict, *, library_token: str | None = None) -> Any:
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("label", sub="set", library=library,
                                   flags={"settings-json": json.dumps(settings)}), library_token=tok)))


# --- Open/close a library (local control only, G27b Task7) ---
#
# The server only has /local/libraries/open,close under local control on 127.0.0.1 (a CLI connected
# to a shared server via --url gets a 404). This doesn't use _with_library (the locked-library
# auto-reunlock) -- the library being opened/closed isn't a library_token-style target (open has no
# target yet; close takes a uuid and isn't about unlocking at all).

def library_open(path: str) -> Any:
    """Open a library window at the given path (if it's already open, no new window opens and the existing uuid is returned)."""
    return json.loads(run(build_argv("library", sub="open", paths=[path])))


def library_close(uuid: str) -> None:
    """Close a library window by uuid."""
    run(build_argv("library", sub="close", text=uuid, json_output=False))


def finder_tags_status(library: str, *, library_token: str | None = None) -> Any:
    """Return the Finder tag sync status (the synced field, whether it's running, whether it's locked)."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("finder-tags", sub="status", library=library),
                        library_token=tok)))


def finder_tags_set(library: str, field: str | None, *, library_token: str | None = None) -> Any:
    """Change which field syncs (None / "none" disables syncing).

    Note: changing the field clears all previously synced values (so a different field's values are
    never mistaken for "the previous tags"). An unknown column name is rejected by the CLI/server
    with a 400 (it never silently falls back to "don't sync")."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("finder-tags", sub="set", library=library,
                                   text=(field or "none")),
                        library_token=tok)))


def finder_tags_resync(library: str, *, library_token: str | None = None) -> Any:
    """Re-sync now and wait for it to finish before returning the result.

    Follows the same path as the app's "Re-sync Finder Tags" menu item, so it doesn't run while locked.
    Measured at 0.4 seconds for 12,000 books, but it can run longer depending on mdfind, so the CLI side
    uses a generous wait."""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("finder-tags", sub="resync", library=library),
                        library_token=tok, timeout=660)))


def rename_files(library: str, ids: list[int], *,
                 preset: str | None = None,
                 fmt: str | None = None,
                 apply: bool = False,
                 library_token: str | None = None) -> Any:
    """Rename files from metadata. With apply=False, only a plan is produced (no file is moved)."""
    argv = ["rename-files"] + [str(i) for i in ids]
    argv += _opt("--library", library)
    argv += _opt("--preset", preset)
    argv += _opt("--format", fmt)
    if apply:
        argv.append("--apply")
    argv.append("--json")
    return json.loads(_with_library(library, library_token,
        lambda tok: run(argv, library_token=tok, timeout=660)))
