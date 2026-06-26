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
