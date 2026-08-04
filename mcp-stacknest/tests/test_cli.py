# SPDX-License-Identifier: MIT
import json
import sys
import os
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import cli  # noqa: E402


def test_build_argv_list():
    argv = cli.build_argv("list", library="Manga", query="ナルト", limit=200)
    assert argv == ["list", "--library", "Manga", "--query", "ナルト", "--limit", "200", "--json"]


def test_build_argv_set_only_given_fields_and_dashes():
    argv = cli.build_argv("set", library="M", book_id=12,
                          fields={"title": "T", "keyword_a": "A", "volume": 3, "author": None})
    assert argv[:3] == ["set", "--library", "M"]
    assert "--title" in argv and "T" in argv
    assert "--keyword-a" in argv and "A" in argv
    assert "--volume" in argv and "3" in argv
    assert "--author" not in argv          # None は付かない
    assert argv[-1] == "12"                # 位置 id は末尾（--json の後）
    assert "--json" in argv


def test_build_argv_rm_trash_and_ids():
    argv = cli.build_argv("rm", library="M", ids=[1, 2, 3], trash=True)
    assert "--trash" in argv
    assert argv[-3:] == ["1", "2", "3"]


def test_build_argv_add_paths():
    argv = cli.build_argv("add", library="M", paths=["/a.cbz", "/b.zip"], preset="p1")
    assert "--preset" in argv and "p1" in argv
    assert argv[-2:] == ["/a.cbz", "/b.zip"]


def test_build_argv_double_dash_blocks_flag_smuggling():
    # `--trash` のような危険な値の path も `--` の後＝位置引数として扱われ、フラグ誤解釈を防ぐ
    argv = cli.build_argv("add", library="M", paths=["--trash", "/x.cbz"])
    sep = argv.index("--")
    assert argv[sep + 1:] == ["--trash", "/x.cbz"]
    # `--` はオプション群（--library/--json 等）の後にあること
    assert argv.index("--library") < sep
    assert argv.index("--json") < sep


def test_run_raises_on_nonzero(monkeypatch):
    class FakeProc:
        returncode = 2
        stdout = ""
        stderr = "認証に失敗しました"
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    with pytest.raises(cli.StacknestError) as e:
        cli.run(["libraries", "--json"])
    assert e.value.exit_code == 2
    assert "認証" in e.value.stderr


def test_run_missing_cli(monkeypatch):
    def boom(*a, **k):
        raise FileNotFoundError()
    monkeypatch.setattr(cli.subprocess, "run", boom)
    with pytest.raises(cli.StacknestError) as e:
        cli.run(["libraries"])
    assert e.value.exit_code == 127


def test_libraries_parses_json(monkeypatch):
    class FakeProc:
        returncode = 0
        stdout = json.dumps([{"id": "u1", "name": "Manga", "locked": False, "bookCount": 3}])
        stderr = ""
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    result = cli.libraries()
    assert result[0]["name"] == "Manga"


def test_add_partial_failure_returns_reply_not_raise(monkeypatch):
    # exit 1（一部 failed）でも reply を返す＝addedIDs を構造化結果として扱える（Option A）
    class FakeProc:
        returncode = 1
        stdout = json.dumps({"addedIDs": [8], "alreadyPresent": [], "failed": ["/bad.cbz"]})
        stderr = ""
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    reply = cli.add("M", ["/ok.cbz", "/bad.cbz"])
    assert reply["addedIDs"] == [8]
    assert reply["failed"] == ["/bad.cbz"]


def test_add_fatal_exit_raises(monkeypatch):
    # exit 2（接続/認証）は例外（stdout 空・stderr にメッセージ）
    class FakeProc:
        returncode = 2
        stdout = ""
        stderr = "サーバに接続できません"
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    with pytest.raises(cli.StacknestError) as e:
        cli.add("M", ["/ok.cbz"])
    assert e.value.exit_code == 2


def test_set_empty_stdout_ok(monkeypatch):
    class FakeProc:
        returncode = 0
        stdout = ""        # set --json は空
        stderr = ""
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    cli.set_meta("M", 12, title="新題")   # 例外が出なければ成功


def test_cli_path_prefers_env(monkeypatch):
    monkeypatch.setenv("STACKNEST_CLI", "/env/stacknest-cli")
    assert cli.cli_path() == "/env/stacknest-cli"


def test_cli_path_reads_defaults(monkeypatch):
    monkeypatch.delenv("STACKNEST_CLI", raising=False)
    monkeypatch.setattr(cli, "_read_default_cli_path", lambda: "/bundled/stacknest-cli")
    assert cli.cli_path() == "/bundled/stacknest-cli"


def test_cli_path_falls_back_to_name(monkeypatch):
    monkeypatch.delenv("STACKNEST_CLI", raising=False)
    monkeypatch.setattr(cli, "_read_default_cli_path", lambda: None)
    assert cli.cli_path() == "stacknest-cli"


# --- 新コマンド ---

def test_build_argv_detail():
    argv = cli.build_argv("detail", library="M", book_id=12)
    assert argv[:3] == ["detail", "--library", "M"]
    assert argv[-1] == "12"
    assert "--json" in argv


def test_build_argv_facets():
    argv = cli.build_argv("facets", library="M", field="author")
    assert argv[:3] == ["facets", "--library", "M"]
    assert argv[-1] == "author"


def test_build_argv_shelves():
    argv = cli.build_argv("shelves", library="M")
    assert argv[:3] == ["shelves", "--library", "M"]


def test_build_argv_me():
    argv = cli.build_argv("me")
    assert argv[0] == "me"


def test_build_argv_set_extended_fields():
    argv = cli.build_argv("set", library="M", book_id=3,
                          fields={"unseen": False, "book_type": 1, "direction": "rtl"})
    assert "--unseen" in argv and "false" in argv
    assert "--book-type" in argv and "1" in argv
    assert "--direction" in argv and "rtl" in argv


def test_detail_parses_json(monkeypatch):
    class FakeProc:
        returncode = 0
        stdout = json.dumps({"id": 5, "title": "T", "bookType": 1})
        stderr = ""
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    assert cli.detail("M", 5)["title"] == "T"


def test_facets_parses_json(monkeypatch):
    class FakeProc:
        returncode = 0
        stdout = json.dumps(["佐藤", "鈴木"])
        stderr = ""
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    assert cli.facets("M", "author") == ["佐藤", "鈴木"]


def test_shelves_parses_json(monkeypatch):
    class FakeProc:
        returncode = 0
        stdout = json.dumps([{"id": 1, "title": "棚", "kind": "user", "isSmart": False}])
        stderr = ""
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    assert cli.shelves("M")[0]["title"] == "棚"


def test_me_parses_json(monkeypatch):
    class FakeProc:
        returncode = 0
        stdout = json.dumps({"role": "write", "tier": "admin", "scope": "all"})
        stderr = ""
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: FakeProc())
    assert cli.me()["tier"] == "admin"


# --- 棚グループ / watch / lock / relink / dedup ---

def test_build_argv_group_shelf_create():
    argv = cli.build_argv("shelf", sub="create", library="M",
                          flags={"title": "棚", "conditions-json": '{"version":1,"match":"all","rules":[]}'}, smart=True)
    assert argv[:2] == ["shelf", "create"]
    assert "--library" in argv and "--title" in argv and "--smart" in argv and "--conditions-json" in argv


def test_build_argv_group_shelf_add_books():
    argv = cli.build_argv("shelf", sub="add-books", library="M", book_id=5, ids=[1, 2])
    assert argv[:2] == ["shelf", "add-books"]
    sep = argv.index("--")
    assert argv[sep + 1:] == ["5", "1", "2"]


def test_build_argv_group_watch_set():
    argv = cli.build_argv("watch", sub="set", library="M", flags={"config-json": "{}"})
    assert argv[:2] == ["watch", "set"]
    assert "--config-json" in argv


def test_build_argv_relink():
    argv = cli.build_argv("relink", library="M", book_id=7, flags={"new-path": "/x.zip"})
    assert argv[0] == "relink"
    assert "--new-path" in argv and "/x.zip" in argv
    assert argv[-1] == "7"


def test_build_argv_lock_set_uses_stdin_flag():
    argv = cli.build_argv("lock", sub="set", library="M", flags={"password-stdin": True})
    assert argv[:2] == ["lock", "set"]
    assert "--password-stdin" in argv
    assert "--password" not in argv


def test_high_level_shelf_delete_uses_rm(monkeypatch):
    captured = {}
    monkeypatch.setattr(cli, "run", lambda argv, **k: captured.setdefault("argv", argv) or "")
    cli.shelf_delete("M", 9)
    assert captured["argv"][:2] == ["shelf", "rm"]


def test_high_level_global_get_path(monkeypatch):
    captured = {}
    def fake_run(argv, **k):
        captured["argv"] = argv; return "{}"
    monkeypatch.setattr(cli, "run", fake_run)
    cli.import_config_global_get()
    assert captured["argv"][:2] == ["import-config-global", "get"]


def test_high_level_global_set_path(monkeypatch):
    captured = {}
    monkeypatch.setattr(cli, "run", lambda argv, **k: captured.setdefault("argv", argv) or "{}")
    cli.import_config_global_set(False, 30)
    assert captured["argv"][:2] == ["import-config-global", "set"]
    assert "--auto-classify" in captured["argv"] and "false" in captured["argv"]
    assert "--thick" in captured["argv"] and "30" in captured["argv"]


def test_high_level_dedup_no_sub(monkeypatch):
    captured = {}
    def fake_run(argv, **k):
        captured["argv"] = argv; return "{}"
    monkeypatch.setattr(cli, "run", fake_run)
    cli.dedup_scan("M")
    assert captured["argv"][0] == "dedup"
    assert "scan" not in captured["argv"]


# --- 整合性検査（integrity・G27a）---

def test_high_level_integrity_scan(monkeypatch):
    captured = {}
    def fake_run(argv, **k):
        captured["argv"] = argv; return "{}"
    monkeypatch.setattr(cli, "run", fake_run)
    cli.integrity_scan("M")
    assert captured["argv"][:2] == ["integrity", "scan"]
    assert "--library" in captured["argv"] and "M" in captured["argv"]


def test_high_level_integrity_status(monkeypatch):
    captured = {}
    def fake_run(argv, **k):
        captured["argv"] = argv; return "{}"
    monkeypatch.setattr(cli, "run", fake_run)
    cli.integrity_status("M")
    assert captured["argv"][:2] == ["integrity", "status"]


def test_high_level_integrity_list_default_status(monkeypatch):
    captured = {}
    def fake_run(argv, **k):
        captured["argv"] = argv; return "{}"
    monkeypatch.setattr(cli, "run", fake_run)
    cli.integrity_list("M")
    assert captured["argv"][:2] == ["integrity", "list"]
    assert "--status" in captured["argv"] and "damaged" in captured["argv"]


def test_high_level_integrity_list_custom_status(monkeypatch):
    captured = {}
    def fake_run(argv, **k):
        captured["argv"] = argv; return "{}"
    monkeypatch.setattr(cli, "run", fake_run)
    cli.integrity_list("M", status="missing")
    assert "--status" in captured["argv"] and "missing" in captured["argv"]


def test_high_level_lock_set_passes_stdin(monkeypatch):
    captured = {}
    def fake_run(argv, **k):
        captured["argv"] = argv; captured["input"] = k.get("input"); return ""
    monkeypatch.setattr(cli, "run", fake_run)
    cli.lock_set("M", "secret")
    assert "--password-stdin" in captured["argv"]
    assert "--password" not in captured["argv"]
    assert captured["input"] == "secret"


# --- env library_token 注入 / 自動再 unlock ---

def test_run_injects_library_token_into_env(monkeypatch):
    captured = {}
    class FakeProc:
        returncode = 0
        stdout = "{}"
        stderr = ""
    def fake_run(cmd, **kwargs):
        captured["env"] = kwargs.get("env")
        return FakeProc()
    monkeypatch.setattr(cli.subprocess, "run", fake_run)
    cli.run(["list", "--json"], library_token="LT123")
    assert captured["env"] is not None
    assert captured["env"].get("STACKNEST_LIBRARY_TOKEN") == "LT123"


def test_run_no_env_override_when_token_absent(monkeypatch):
    captured = {}
    class FakeProc:
        returncode = 0
        stdout = "{}"
        stderr = ""
    def fake_run(cmd, **kwargs):
        captured["env"] = kwargs.get("env")
        return FakeProc()
    monkeypatch.setattr(cli.subprocess, "run", fake_run)
    cli.run(["list", "--json"])
    assert captured["env"] is None


def test_build_argv_unchanged_for_library_token():
    argv = cli.build_argv("list", library="M")
    assert "STACKNEST_LIBRARY_TOKEN" not in " ".join(argv)
    assert "--library-token" not in argv


def test_build_argv_grant_create():
    argv = cli.build_argv("grant", sub="create",
                          flags={"label": "fam", "tier": "edit", "scope-json": '{"libraries":["a"]}'})
    assert argv[:2] == ["grant", "create"]
    assert "--label" in argv and "fam" in argv
    assert "--tier" in argv and "edit" in argv
    assert "--scope-json" in argv


def test_build_argv_stamp_clear_and_ids():
    argv = cli.build_argv("stamp", library="M", flags={"field": "genre", "clear": True}, ids=[1, 2])
    assert argv[:1] == ["stamp"]
    assert "--field" in argv and "genre" in argv
    assert "--clear" in argv
    assert argv[-2:] == ["1", "2"]


def test_build_argv_list_filter_browse():
    argv = cli.build_argv("list", library="M",
                          flags={"sort": "dateAdded", "order": "desc",
                                 "filter-json": "{}", "browse-json": "[]"})
    assert "--sort" in argv and "dateAdded" in argv
    assert "--order" in argv and "desc" in argv
    assert "--filter-json" in argv
    assert "--browse-json" in argv


def test_stale_token_auto_reunlock_and_retry(monkeypatch):
    """exit 3(stale) → password キャッシュ有りなら自動再 unlock＋リトライで成功し、
    新トークンが STACKNEST_LIBRARY_TOKEN に書き戻される（spec §2.1）。"""
    cli._library_tokens.clear()
    cli._library_passwords.clear()
    monkeypatch.delenv("STACKNEST_LIBRARY_TOKEN", raising=False)
    cli._library_tokens["Secret"] = "OLD"
    cli._library_passwords["Secret"] = "pw"

    def fake_exec(argv, *, timeout=60, input=None, library_token=None):
        class P:
            stderr = ""
        if argv[0] == "unlock":
            P.returncode = 0
            P.stdout = '{"libraryToken": "NEW"}'
            return P
        if library_token == "OLD":
            P.returncode = 3
            P.stdout = ""
            P.stderr = "forbidden"
            return P
        P.returncode = 0
        P.stdout = '{"items": [], "total": 0, "page": 1, "perPage": 100}'
        return P
    monkeypatch.setattr(cli, "_exec", fake_exec)

    result = cli.list_books("Secret")
    assert result["total"] == 0
    assert cli._library_tokens["Secret"] == "NEW"
    assert os.environ.get("STACKNEST_LIBRARY_TOKEN") == "NEW"


def test_stale_token_without_password_raises(monkeypatch):
    """exit 3 でも password 未キャッシュなら自動更新せず例外（外部 token を直接渡したケース）。"""
    cli._library_tokens.clear()
    cli._library_passwords.clear()
    def fake_exec(argv, *, timeout=60, input=None, library_token=None):
        class P:
            returncode = 3
            stdout = ""
            stderr = "forbidden"
        return P
    monkeypatch.setattr(cli, "_exec", fake_exec)
    with pytest.raises(cli.StacknestError) as e:
        cli.list_books("Secret", library_token="EXTERNAL")
    assert e.value.exit_code == 3
    assert "再解錠" in e.value.stderr


def test_stamp_definitions_set_wraps_into_dto_and_unwraps_reply(monkeypatch):
    """MCP は内側マップを受け取り CLI へ StampDefinitionsDTO {"definitions":{...}} で渡す。
    返りは内側マップにアンラップする（スモークで keyNotFound("definitions") を検出した回帰防止）。"""
    captured = {}
    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return '{"definitions": {"genre": ["A"]}}'
    monkeypatch.setattr(cli, "run", fake_run)
    result = cli.stamp_definitions_set("L", {"genre": ["A"]})
    i = captured["argv"].index("--definitions-json")
    assert json.loads(captured["argv"][i + 1]) == {"definitions": {"genre": ["A"]}}
    assert result == {"genre": ["A"]}


def test_stamp_definitions_get_unwraps(monkeypatch):
    monkeypatch.setattr(cli, "run", lambda argv, **k: '{"definitions": {"genre": ["A", "B"]}}')
    assert cli.stamp_definitions_get("L") == {"genre": ["A", "B"]}
