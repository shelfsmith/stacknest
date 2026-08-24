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
    """subprocess 実行（バイナリ不在/タイムアウトは StacknestError へ）。非0でも raise しない。
    library_token が指定されたら STACKNEST_LIBRARY_TOKEN として env に注入する（argv に出さない＝履歴非露出）。"""
    cli = cli_path()
    env = None
    if library_token:
        env = dict(os.environ)
        env["STACKNEST_LIBRARY_TOKEN"] = library_token
    try:
        return subprocess.run(
            [cli, *argv], capture_output=True, text=True, timeout=timeout, input=input, env=env)
    except FileNotFoundError:
        raise StacknestError(127, f"stacknest CLI が見つかりません: {cli}（環境変数 STACKNEST_CLI を確認）")
    except subprocess.TimeoutExpired:
        raise StacknestError(124, f"stacknest CLI がタイムアウトしました（{timeout}s）")


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
    """library 対象操作の実行ラッパ。
    - explicit_token があればそれを使う。無ければキャッシュ token を使う（どちらも無ければ None）。
    - exit 3(locked/stale) で失敗し、当該 library の password をキャッシュ済みなら、
      自動で再 unlock → 新 token をキャッシュ＆書き戻し（STACKNEST_LIBRARY_TOKEN）→ 1 回だけリトライ。
    - password 未キャッシュ（外部取得 token を直接渡した等）なら自動更新せず明示エラー。
    call は (token: str | None) -> str（run() の stdout）を返す callable。"""
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
                (e.stderr or "") + "\n（ロック庫なら stacknest_unlock で再解錠が必要です。または権限不足(tier)の可能性があります）")
        unlock(library, password)                 # 再 unlock（キャッシュ＆ STACKNEST_LIBRARY_TOKEN を更新）
        return call(_library_tokens[library])     # 新トークンで 1 回だけリトライ


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
    """ロック庫を解錠し {"libraryToken": ...} を返す（パスワードは stdin 経由・argv 非露出）。
    成功時に token/password をセッションキャッシュし、STACKNEST_LIBRARY_TOKEN を書き戻す（spec §2.1）。"""
    out = run(build_argv("unlock", library=library, flags={"password-stdin": True}),
              input=password)
    reply = json.loads(out)
    token = reply.get("libraryToken")
    if token:
        _library_tokens[library] = token
        _library_passwords[library] = password
        os.environ["STACKNEST_LIBRARY_TOKEN"] = token
    return reply


# --- 棚（shelf）CRUD ---

def shelf_create(library: str, title: str, *,
                 smart: bool = False, conditions: dict | None = None,
                 library_token: str | None = None) -> Any:
    """棚を作成する。smart=True でスマート棚、conditions で条件 JSON を渡す。"""
    flags: dict[str, Any] = {"title": title}
    if conditions is not None:
        flags["conditions-json"] = json.dumps(conditions)
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="create", library=library, flags=flags, smart=smart),
                        library_token=tok)))


def shelf_delete(library: str, shelf_id: int, *, library_token: str | None = None) -> None:
    """棚を削除する。"""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="rm", library=library,
                                   book_id=shelf_id, json_output=False), library_token=tok))


def shelf_rename(library: str, shelf_id: int, title: str, *, library_token: str | None = None) -> None:
    """棚をリネームする。"""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="rename", library=library, book_id=shelf_id,
                                   flags={"title": title}, json_output=False), library_token=tok))


def shelf_conditions_get(library: str, shelf_id: int, *, library_token: str | None = None) -> Any:
    """スマート棚の条件 JSON を取得する。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="conditions-get", library=library, book_id=shelf_id),
                        library_token=tok)))


def shelf_conditions_set(library: str, shelf_id: int, conditions: dict, *,
                         library_token: str | None = None) -> None:
    """スマート棚の条件 JSON を更新する。"""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="conditions-set", library=library, book_id=shelf_id,
                                   flags={"conditions-json": json.dumps(conditions)}, json_output=False),
                        library_token=tok))


def shelf_add_books(library: str, shelf_id: int, ids: list[int], *,
                    library_token: str | None = None) -> None:
    """手動棚に本を追加する。"""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="add-books", library=library,
                                   book_id=shelf_id, ids=ids, json_output=False), library_token=tok))


def shelf_remove_books(library: str, shelf_id: int, ids: list[int], *,
                       library_token: str | None = None) -> None:
    """手動棚から本を除く。"""
    _with_library(library, library_token,
        lambda tok: run(build_argv("shelf", sub="remove-books", library=library,
                                   book_id=shelf_id, ids=ids, json_output=False), library_token=tok))


# --- フォルダ監視（watch）---

def watch_get(library: str, *, library_token: str | None = None) -> Any:
    """ライブラリの watch 設定を取得する。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("watch", sub="get", library=library), library_token=tok)))


def watch_set(library: str, config: dict, *, library_token: str | None = None) -> None:
    """ライブラリの watch 設定を更新する。"""
    _with_library(library, library_token,
        lambda tok: run(build_argv("watch", sub="set", library=library,
                                   flags={"config-json": json.dumps(config)}, json_output=False),
                        library_token=tok))


# --- ロック（lock）---

def lock_set(library: str, password: str, *, current_password: str | None = None,
            library_token: str | None = None) -> None:
    """ライブラリにパスワードロックを設定・変更する（パスワードは stdin 経由で渡す・argv 非露出）。
    G27a Task6: 既存ロックの変更には current_password が必須（サーバが既存ハッシュの有無で判定）。
    新規設定時は current_password 不要。両方を stdin 経由で渡す場合は
    「現在のパスワード\\n新しいパスワード」の2行として CLI へ渡す（1回の stdin で両方運ぶ規約）。"""
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
    """ライブラリのパスワードロックを解除する。
    G27a Task6: 既存ロックがある場合は current_password が必須（stdin 経由・argv 非露出）。"""
    flags: dict[str, Any] = {}
    stdin_payload = None
    if current_password is not None:
        flags["current-password-stdin"] = True
        stdin_payload = current_password
    _with_library(library, library_token,
        lambda tok: run(build_argv("lock", sub="clear", library=library, flags=flags, json_output=False),
                        input=stdin_payload, library_token=tok))


# --- インポート設定（import-config）---

def import_config_get(library: str, *, library_token: str | None = None) -> Any:
    """ライブラリのインポート設定を取得する。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("import-config", sub="get", library=library), library_token=tok)))


def import_config_set(library: str, *,
                      auto_classify: bool | None = None,
                      thick: int | None = None,
                      library_token: str | None = None) -> None:
    """ライブラリのインポート設定 override を更新する（指定分のみ）。
    auto_classify は bool（文字列 "true"/"false" として CLI へ）、thick は整数。"""
    flags: dict[str, Any] = {}
    if auto_classify is not None:
        flags["auto-classify"] = "true" if auto_classify else "false"
    if thick is not None:
        flags["thick"] = thick
    _with_library(library, library_token,
        lambda tok: run(build_argv("import-config", sub="set", library=library,
                                   flags=flags, json_output=False), library_token=tok))


def import_config_global_get() -> Any:
    """グローバルインポート設定を取得する。"""
    return json.loads(run(build_argv("import-config-global", sub="get")))


def import_config_global_set(auto_classify: bool, thick: int) -> None:
    """グローバルインポート設定を更新する（両値必須・CLI が必須オプション）。"""
    flags: dict[str, Any] = {
        "auto-classify": "true" if auto_classify else "false",
        "thick": thick,
    }
    run(build_argv("import-config-global", sub="set", flags=flags, json_output=False))


# --- リンク修復（relink）---

def relink(library: str, book_id: int, new_path: str, *, library_token: str | None = None) -> None:
    """本のファイルパスを新しいパスに更新する（ファイル移動後のリンク修復）。"""
    _with_library(library, library_token,
        lambda tok: run(build_argv("relink", library=library, book_id=book_id,
                                   flags={"new-path": new_path}, json_output=False), library_token=tok))


# --- 重複検出（dedup）---

def dedup_scan(library: str, *, library_token: str | None = None) -> Any:
    """ライブラリ内の重複候補を検出して結果を返す。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("dedup", library=library), library_token=tok)))


# --- 整合性検査（integrity・G27a）---

def integrity_scan(library: str, *, library_token: str | None = None) -> Any:
    """pages 未取得の本を開いて分類する簡易チェックを実行し、件数の内訳を返す。

    実測 65 候補 ≈ 4 分（1 冊 ≈ 3.46s）かかるため、既定の 60s タイムアウトでは確実に
    間に合わない。この呼び出しだけ長めのタイムアウトを与える（他の呼び出しの既定は変えない）。
    同期 1 リクエストで待つ形自体は既知の制約 — 非同期ジョブ化＋ポーリングは Phase G27b で検討する。
    """
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="scan"),
                        timeout=1800, library_token=tok)))


def integrity_status(library: str, *, library_token: str | None = None) -> Any:
    """整合性検査の集計を返す（checked / unchecked / damaged / degraded）。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="status"), library_token=tok)))


def integrity_list(library: str, *, status: str = "damaged",
                   library_token: str | None = None) -> Any:
    """指定した状態の本を一覧する（ok / damaged / empty / missing / unsupported）。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="list",
                                   flags={"status": status}), library_token=tok)))


# --- フル CRC スキャン（非同期ジョブ・G27b Task5）---
#
# 実測 4.464 秒/冊・22,880 冊規模で約 31 時間かかる。integrity_scan（簡易チェック）と違い
# サーバ側は非同期ジョブとして開始するだけなので、ここでは長いタイムアウトを与えない
# （既定 60s のままでよい — CLI 自体が起動確認したらすぐ返る設計のため）。

def integrity_full_scan(library: str, *, mode: str = "unchecked",
                        library_token: str | None = None) -> str:
    """全冊 CRC 検証をバックグラウンドジョブとして開始する。CLI の案内メッセージ
    （起動できた／既に実行中だった、のいずれか）をそのまま stdout 文字列として返す
    （JSON ではない ―― サーバ応答は 202/409 のみでボディを持たないため）。"""
    return _with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="full-scan",
                                   flags={"mode": mode}), library_token=tok))


def integrity_job_status(library: str, *, library_token: str | None = None) -> Any:
    """実行中のメンテナンスジョブ（full-scan・complete-metadata・compress-covers 等、
    すべて同じジョブレジストリを共有）の進捗を返す。running/job/done/total/startedAt。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="job-status"),
                        library_token=tok)))


def integrity_cancel(library: str, *, library_token: str | None = None) -> str:
    """実行中のメンテナンスジョブ（full-scan 含む）を中断する。実行中ジョブが無ければ no-op。
    full-scan 専用の中断コマンドは無い（既存の maintenance/cancel を共用する）。"""
    return _with_library(library, library_token,
        lambda tok: run(build_argv("integrity", library=library, sub="cancel"),
                        library_token=tok))


# --- グラント CRUD（admin）---

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


# --- stamp / label（per-library）---

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
    # サーバ/CLI は StampDefinitionsDTO {"definitions": {col:[...]}} で授受するが、
    # MCP ツールは内側マップ {col:[...]} を扱う（set と対称・label と同様に「中身」を直接扱う）。
    raw = json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("stamp-definitions", sub="get", library=library), library_token=tok)))
    return raw.get("definitions", raw) if isinstance(raw, dict) else raw


def stamp_definitions_set(library: str, definitions: dict, *,
                          library_token: str | None = None) -> Any:
    # 内側マップ {col:[...]} を StampDefinitionsDTO {"definitions": {...}} にラップして渡す
    # （CLI/サーバは DTO 形を要求するため。素の内側マップだと keyNotFound("definitions") になる）。
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


# --- ライブラリ開閉（ローカル制御専用・G27b Task7）---
#
# サーバ側は /local/libraries/open,close を 127.0.0.1 のローカル制御にのみ持つ（共有サーバに
# --url で繋いだ CLI では 404 になる）。ここは _with_library（ロック庫の自動再解錠）を使わない
# ―― これから開く/閉じる庫は library_token 前提の対象ではない（open は対象がまだ無い、
# close は uuid 指定でありそもそもロック解錠の話ではない）。

def library_open(path: str) -> Any:
    """パスを指定してライブラリウィンドウを開く（既に開いていれば新規ウィンドウを開かず既存 uuid を返す）。"""
    return json.loads(run(build_argv("library", sub="open", paths=[path])))


def library_close(uuid: str) -> None:
    """uuid を指定してライブラリウィンドウを閉じる。"""
    run(build_argv("library", sub="close", text=uuid, json_output=False))


def finder_tags_status(library: str, *, library_token: str | None = None) -> Any:
    """Finder タグ同期の状態（同期対象の項目・走行中か・施錠中か）を返す。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("finder-tags", sub="status", library=library),
                        library_token=tok)))


def finder_tags_resync(library: str, *, library_token: str | None = None) -> Any:
    """今すぐ再照合し、終わるまで待って結果を返す。

    アプリのメニュー「Finder タグを再照合」と同じ経路を通るので、施錠中は走らない。
    12,000 冊で実測 0.4 秒だが mdfind 次第で伸びるため、CLI 側で長めの待ちを取っている。"""
    return json.loads(_with_library(library, library_token,
        lambda tok: run(build_argv("finder-tags", sub="resync", library=library),
                        library_token=tok, timeout=660)))
