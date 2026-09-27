#!/usr/bin/env python3
"""l10n-lint のテスト（標準ライブラリのみ）。"""
import contextlib, importlib.util, io, json, os, pathlib, tempfile, textwrap, time, unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("lint", ROOT / "Scripts" / "l10n-lint.py")
lint = importlib.util.module_from_spec(spec); spec.loader.exec_module(lint)


def tree(files: dict) -> pathlib.Path:
    d = pathlib.Path(tempfile.mkdtemp())
    for rel, body in files.items():
        p = d / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(textwrap.dedent(body), encoding="utf-8")
    return d


def kinds(root, **kw):
    return sorted(f.kind for f in lint.run(root, **kw))


class SwiftSources(unittest.TestCase):
    def test_bare_literal_is_flagged(self):
        r = tree({"Sources/AppCore/A.swift": 'let s = "削除"\n', "Sources/StackNestL10n/Tables/L10n+X.swift": ""})
        self.assertEqual(kinds(r), ["swift-literal"])

    def test_l10n_call_with_entry_passes(self):
        r = tree({
            "Sources/AppCore/A.swift": 'let s = L10n.text("削除")\n',
            "Sources/StackNestL10n/Tables/L10n+X.swift": 'extension L10nTable { static let x: [String: L10nEntry] = ["削除": L10nEntry("Delete")] }\n',
        })
        self.assertEqual(kinds(r), [])

    def test_l10n_call_without_entry_is_missing(self):
        r = tree({"Sources/AppCore/A.swift": 'let s = L10n.format("「%@」を削除", n)\n', "Sources/StackNestL10n/Tables/L10n+X.swift": ""})
        self.assertEqual(kinds(r), ["swift-missing"])

    def test_comments_logs_and_ignore_are_skipped(self):
        r = tree({"Sources/AppCore/A.swift": '''
            // 日本語のコメント
            /// 日本語の doc
            /* 日本語 */
            Self.logger.error("失敗")
            let x = "上巻" // l10n:ignore parser token
        ''', "Sources/StackNestL10n/Tables/L10n+X.swift": ""})
        self.assertEqual(kinds(r), [])

    def test_comparison_is_flagged(self):
        r = tree({"Sources/AppCore/A.swift": 'if label == "お気に入り" {}\n', "Sources/StackNestL10n/Tables/L10n+X.swift": ""})
        self.assertIn("compare", kinds(r))

    def test_specifier_mismatch_in_table(self):
        r = tree({"Sources/StackNestL10n/Tables/L10n+X.swift": 'extension L10nTable { static let x: [String: L10nEntry] = ["%lld 件": L10nEntry("%@ items")] }\n'})
        self.assertEqual(kinds(r), ["specifier"])

    def test_ignore_on_line_above_and_paths_filter(self):
        r = tree({
            "Sources/AppCore/A.swift": 'let m = """\n    // l10n:ignore\n    """\n// l10n:ignore developer text\nlet c = """\n    複数行\n    """\n',
            "Sources/AppCore/B.swift": 'let s = "削除"\n',
            "Sources/StackNestL10n/Tables/L10n+X.swift": "",
        })
        self.assertEqual([(f.kind, f.path) for f in lint.run(r)], [("swift-literal", "Sources/AppCore/B.swift")])
        self.assertEqual(kinds(r, paths=["Sources/AppCore/A.swift"]), [])
        self.assertEqual(kinds(r, paths=[str(r / "Sources/AppCore")]), ["swift-literal"])

    # Controller amendment (after the Task 3 review): specifiers are compared in argument order.
    def test_specifier_reorder_without_positions_is_flagged(self):
        r = tree({"Sources/StackNestL10n/Tables/L10n+X.swift": 'extension L10nTable { static let x: [String: L10nEntry] = ["%@ の %lld 件": L10nEntry("%lld items in %@")] }\n'})
        self.assertEqual(kinds(r), ["specifier"])

    def test_specifier_positional_reorder_passes(self):
        r = tree({"Sources/StackNestL10n/Tables/L10n+X.swift": 'extension L10nTable { static let x: [String: L10nEntry] = ["%@ の %lld 件": L10nEntry("%2$lld items in %1$@")] }\n'})
        self.assertEqual(kinds(r), [])

    def test_specifier_plural_form_checked(self):
        r = tree({"Sources/StackNestL10n/Tables/L10n+X.swift": 'extension L10nTable { static let x: [String: L10nEntry] = ["%lld 件": L10nEntry(one: "one item", other: "%lld items")] }\n'})
        self.assertEqual(kinds(r), ["specifier"])

    def test_specifier_in_xcstrings(self):
        cat = {"%lld 件": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%@ items"}}}}}
        r = tree({"App/StackNest/Localizable.xcstrings": json.dumps({"sourceLanguage": "ja", "strings": cat, "version": "1.0"}, ensure_ascii=False),
                  "Sources/StackNestL10n/Tables/L10n+X.swift": ""})
        self.assertEqual(kinds(r), ["specifier"])

    def test_tokenizer_edge_cases(self):
        src = (
            'let a = "\\(flag ? "はい" : "No") done"\n'
            'let b = #"raw "引用" \\#(x)"#\n'
            'let c = """\n    複数行\n    """\n'
            'Self.coverLogger.error(\n    "複数行のログ \\(x)")\n'
            'if s.hasPrefix("第") {}\n'
            'switch v { case "上", "下": break default: break }\n'
            'let ok = L10n.plural("%lld 件", count: n, n)\n'
            '/* 外 /* 入れ子 */ まだコメント "偽" */\n'
        )
        r = tree({"Sources/AppCore/A.swift": src,
                  "Sources/StackNestL10n/Tables/L10n+X.swift": 'extension L10nTable { static let x: [String: L10nEntry] = ["%lld 件": L10nEntry(one: "%lld item", other: "%lld items")] }\n'})
        found = sorted((f.kind, f.text) for f in lint.run(r))
        self.assertEqual(found, sorted([
            ("swift-literal", "はい"), ("swift-literal", 'raw "引用" \\(…)'), ("swift-literal", "複数行"),
            ("compare", "第"), ("compare", "上"), ("compare", "下"),
        ]))


    # G56-S1: blind spots (regex literals, array contains, one-literal ignores).
    def test_g56_regex_literal_with_japanese_is_compare(self):
        r = tree({"Sources/AppCore/A.swift": '''
            let r = /第(\\d+)巻/
            let s = #/上巻/#
            let ok = /第(\\d+)巻/ // l10n:ignore parser for stored titles
        ''', "Sources/StackNestL10n/Tables/L10n+X.swift": ""})
        self.assertEqual(kinds(r), ["compare", "compare"])

    def test_g56_division_is_not_regex(self):
        r = tree({"Sources/AppCore/A.swift": '''
            let a = b / c / d
            let t = L10n.text("上巻")
        ''', "Sources/StackNestL10n/Tables/L10n+X.swift": '"上巻": L10nEntry("Vol. 1"),'})
        self.assertEqual(kinds(r), [])

    def test_g56_array_contains_is_compare(self):
        r = tree({"Sources/AppCore/A.swift": '''
            if ["上巻", "下巻"].contains(x) { }
            if ["上巻"].firstIndex(of: x) != nil { }
        ''', "Sources/StackNestL10n/Tables/L10n+X.swift": ""})
        self.assertEqual(kinds(r), ["compare", "compare", "compare"])

    def test_g56_ignore_with_two_japanese_literals_is_void(self):
        r = tree({"Sources/AppCore/A.swift": '''
            let a = "上巻"; let b = "下巻" // l10n:ignore
            let c = "中巻" // l10n:ignore single literal still ignored
        ''', "Sources/StackNestL10n/Tables/L10n+X.swift": ""})
        self.assertEqual(kinds(r), ["swift-literal", "swift-literal"])


class Allowlist(unittest.TestCase):
    def test_allowlisted_file_is_skipped(self):
        r = tree({"Sources/AppCore/FilenameParser.swift": 'let t = ["上", "下"]\n', "Sources/StackNestL10n/Tables/L10n+X.swift": "",
                  "Scripts/l10n-allowlist.txt": "Sources/AppCore/FilenameParser.swift  # parser tokens\n"})
        self.assertEqual(kinds(r), [])


class App(unittest.TestCase):
    def _app(self, src, keys, catalog):
        # Location-less entries match within their own source file (G56), so name the real one.
        sd = {"source": "App/StackNest/V.swift", "tables": {"Localizable": [{"key": k} for k in keys]}, "version": 1}
        return tree({
            "App/StackNest/V.swift": src,
            "App/StackNest/Localizable.xcstrings": json.dumps({"sourceLanguage": "ja", "strings": catalog, "version": "1.0"}, ensure_ascii=False),
            "App/build/Build/Intermediates.noindex/x.stringsdata": json.dumps(sd, ensure_ascii=False),
            "Sources/StackNestL10n/Tables/L10n+X.swift": "",
        })

    def test_extracted_and_translated_passes(self):
        cat = {"%lld 件選択中": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%lld selected"}}}}}
        r = self._app('Text("\\(n) 件選択中")\n', ["%lld 件選択中"], cat)
        self.assertEqual(kinds(r), [])

    def test_not_extracted_is_app_literal(self):
        r = self._app('para("日本語の段落")\n', [], {})
        self.assertEqual(kinds(r), ["app-literal"])

    def test_extracted_without_en_is_app_missing(self):
        r = self._app('Text("削除")\n', ["削除"], {"削除": {}})
        self.assertEqual(kinds(r), ["app-missing"])

    def test_fragment_counts_as_translated(self):
        r = self._app('Text("削除")\n', ["削除"], {})
        frag = r / "tools/l10n/fragments/U1.json"; frag.parent.mkdir(parents=True, exist_ok=True)
        frag.write_text(json.dumps({"削除": {"en": "Delete"}}, ensure_ascii=False), encoding="utf-8")
        self.assertEqual(kinds(r, fragments=r / "tools/l10n/fragments"), [])

    def test_g56_same_text_extracted_in_other_file_does_not_pass(self):
        # B.swift の "閉じる" は抽出されていない。A.swift の位置無しの抽出物で合格にしない。
        r = tree({"App/StackNest/A.swift": 'Text("閉じる")\n',
                  "App/StackNest/B.swift": 'let x = "閉じる"\n',
                  "App/StackNest/Localizable.xcstrings": json.dumps({"strings": {"閉じる": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Close"}}}}}})})
        now = time.time() + 100
        write_sd(r, "StackNest.build/Debug/A.stringsdata", "App/StackNest/A.swift", [("閉じる", 0)], now)  # 位置無し
        write_sd(r, "StackNest.build/Debug/B.stringsdata", "App/StackNest/B.swift", [], now)
        self.assertEqual(kinds(r), ["app-literal"])

    def test_g56_location_less_entry_without_source_matches_by_text(self):
        r = self._app('Text("閉じる")\n', [], {"閉じる": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Close"}}}}})
        sd = r / "App/build/Build/Intermediates.noindex/x.stringsdata"
        sd.write_text(json.dumps({"tables": {"Localizable": [{"key": "閉じる"}]}, "version": 1}, ensure_ascii=False), encoding="utf-8")
        self.assertEqual(kinds(r), [])

    def test_g56_mixed_debug_release_root_is_usage_error(self):
        r = tree({"App/StackNest/A.swift": 'Text("閉じる")\n'})
        now = time.time() + 100
        write_sd(r, "StackNest.build/Debug/A.stringsdata", "App/StackNest/A.swift", [("閉じる", 1)], now)
        write_sd(r, "StackNest.build/Release/A.stringsdata", "App/StackNest/A.swift", [("閉じる", 1)], now)
        self.assertEqual(cli(r, "--strict")[0], 2)


class AppDottedKeys(unittest.TestCase):
    """G55 S2-C: an English dotted key with the original Japanese as `defaultValue`.

    Xcode 26 extracts `String(localized: "k", defaultValue: "日本語")` as
    {"key": "k", "value": "日本語", "location": …} (checked against a real build).
    """
    SRC = 'Section(String(localized: "sidebar.section.smartShelves", defaultValue: "スマートシェルフ")) {}\n'
    KEY = "sidebar.section.smartShelves"

    def _tree(self, catalog, fragment=None, value="スマートシェルフ"):
        r = tree({
            "App/StackNest/V.swift": self.SRC,
            "App/StackNest/Localizable.xcstrings": json.dumps({"sourceLanguage": "ja", "strings": catalog, "version": "1.0"}, ensure_ascii=False),
            "Sources/StackNestL10n/Tables/L10n+X.swift": "",
        })
        entry = {"comment": "", "key": self.KEY, "location": {"startingColumn": 9, "startingLine": 1}}
        if value is not None:
            entry["value"] = value
        f = r / "App/build/Build/Intermediates.noindex/V.stringsdata"; f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"source": str((r / "App/StackNest/V.swift").resolve()),
                                 "tables": {"Localizable": [entry]}, "version": 1}, ensure_ascii=False), encoding="utf-8")
        t = time.time() + 10; os.utime(f, (t, t))
        if fragment is not None:
            d = r / "tools/l10n/fragments"; d.mkdir(parents=True, exist_ok=True)
            (d / "S2C.json").write_text(json.dumps(fragment, ensure_ascii=False), encoding="utf-8")
        return r

    @staticmethod
    def _entry(en=None, ja=None):
        locs = {}
        if en is not None:
            locs["en"] = {"stringUnit": {"state": "translated", "value": en}}
        if ja is not None:
            locs["ja"] = {"stringUnit": {"state": "translated", "value": ja}}
        return {"localizations": locs}

    def test_default_value_literal_counts_as_extracted(self):
        r = self._tree({self.KEY: self._entry("Smart Shelves", "スマートシェルフ")})
        self.assertEqual(kinds(r), [])

    def test_dotted_key_without_english_is_app_missing(self):
        r = self._tree({})
        self.assertEqual(kinds(r), ["app-missing"])

    def test_dotted_key_without_japanese_value_is_app_missing(self):
        # Without a `ja` localization the Japanese UI could show the dotted key itself.
        r = self._tree({self.KEY: self._entry("Smart Shelves")})
        self.assertEqual(kinds(r), ["app-missing"])

    def test_japanese_value_differing_from_default_is_app_missing(self):
        r = self._tree({self.KEY: self._entry("Smart Shelves", "スマート棚")})
        self.assertEqual(kinds(r), ["app-missing"])

    def test_fragment_with_ja_counts_as_translated(self):
        r = self._tree({}, fragment={self.KEY: {"ja": "スマートシェルフ", "en": "Smart Shelves"}})
        self.assertEqual(kinds(r, fragments=r / "tools/l10n/fragments"), [])

    def test_literal_other_than_the_default_value_is_still_app_literal(self):
        r = self._tree({self.KEY: self._entry("Smart Shelves", "スマートシェルフ")}, value="別の文字列")
        self.assertIn("app-literal", kinds(r))

    def test_specifiers_compare_with_the_japanese_value_not_the_key(self):
        ok = self._tree({}, fragment={"list.count": {"ja": "%lld 件", "en": "%lld items"}, self.KEY: {"ja": "スマートシェルフ", "en": "Smart Shelves"}})
        self.assertEqual(kinds(ok, fragments=ok / "tools/l10n/fragments"), [])
        bad = self._tree({"list.count": {**self._entry("%@ items", "%lld 件")}, self.KEY: self._entry("Smart Shelves", "スマートシェルフ")})
        self.assertEqual(kinds(bad), ["specifier"])


class Web(unittest.TestCase):
    def test_web_literal_missing_and_passing(self):
        r = tree({
            "Sources/LibraryServer/Resources/web/app.js": "el.textContent = '読み込み中';\nb.textContent = t('閉じる');\nc.textContent = t('戻る');\n// 日本語のコメント\n",
            "Sources/LibraryServer/Resources/web/i18n-en.js": "export const EN = { '閉じる': 'Close' };\n",
            "Sources/LibraryServer/Resources/web/index.html": '<button data-i18n="閉じる">閉じる</button><p>説明</p>\n',
            "Sources/StackNestL10n/Tables/L10n+X.swift": "",
            "Scripts/l10n-allowlist.txt": "Sources/LibraryServer/Resources/web/i18n-en.js  # dict\n",
        })
        self.assertEqual(kinds(r), ["web-literal", "web-literal", "web-missing"])

    def test_js_tokenizer_and_web_specifier(self):
        r = tree({
            "Sources/LibraryServer/Resources/web/app.js": (
                "const re = /['\"]/g; const x = a / b; // 'コメント'\n"
                "el.textContent = `${n} 冊 ${t('「{title}」を開く', { title: `${x}` })}`;\n"
                "if (mode === '一覧') {}\n"
                "console.warn('デバッグ');\n"
                "/* '日本語' */ y = t(\"{n} 冊\", { n, count: n });\n"
            ),
            "Sources/LibraryServer/Resources/web/i18n-en.js": "export const EN = {\n  '「{title}」を開く': 'Open “{name}”',\n  '{n} 冊': { one: '{n} book', other: '{n} books' },\n};\n",
            "Sources/LibraryServer/Resources/web/index.html": '<!-- 日本語 --><button aria-label="戻る">x</button><input placeholder="検索" data-i18n-placeholder="検索">\n',
            "Sources/StackNestL10n/Tables/L10n+X.swift": "",
            "Scripts/l10n-allowlist.txt": "Sources/LibraryServer/Resources/web/i18n-en.js  # dict\n",
        })
        found = sorted((f.kind, f.text) for f in lint.run(r))
        self.assertEqual(found, sorted([
            ("compare", "一覧"), ("specifier", "「{title}」を開く -> Open “{name}”"),
            ("web-literal", "${…} 冊 ${…}"), ("web-literal", 'aria-label="戻る"'), ("web-missing", "検索"),
        ]))


# ---------------------------------------------------------------------------
# Fix round 1 (review of Task 4): the gate must not pass without checking anything.
# ---------------------------------------------------------------------------

def cli(root, *args, cwd=None):
    """Run main() quietly; returns (exit code, stdout)."""
    out, err = io.StringIO(), io.StringIO()
    old = os.getcwd()
    try:
        if cwd:
            os.chdir(cwd)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = lint.main(["--root", str(root), *args])
    finally:
        os.chdir(old)
    return rc, out.getvalue() + err.getvalue()


def write_sd(root, name, source_rel, keys, mtime):
    """A .stringsdata in Xcode's real shape (absolute source, locations) with a chosen mtime."""
    f = root / "App/build/Build/Intermediates.noindex" / name
    f.parent.mkdir(parents=True, exist_ok=True)
    entries = [{"comment": "", "key": k, "location": {"startingColumn": 1, "startingLine": line}} for k, line in keys]
    f.write_text(json.dumps({"source": str((root / source_rel).resolve()), "tables": {"Localizable": entries} if entries else {},
                             "version": 1}, ensure_ascii=False), encoding="utf-8")
    os.utime(f, (mtime, mtime))
    return f


class Paths(unittest.TestCase):
    def setUp(self):
        self.r = tree({"Sources/AppCore/B.swift": 'let s = "削除"\n', "Sources/StackNestL10n/Tables/L10n+X.swift": "",
                       "docs/notes.md": "x\n"})

    def test_nonexistent_path_is_usage_error(self):
        self.assertEqual(cli(self.r, "--paths", str(self.r / "Sources/AppCore/Typo.swift"))[0], 2)

    def test_path_outside_root_is_usage_error(self):
        other = tree({"Sources/AppCore/B.swift": 'let s = "削除"\n'})
        self.assertEqual(cli(self.r, "--paths", str(other / "Sources/AppCore/B.swift"))[0], 2)

    def test_relative_paths_resolve_against_cwd(self):
        self.assertEqual(cli(self.r, "--strict", "--paths", "AppCore/B.swift", cwd=self.r / "Sources")[0], 1)
        # The same text relative to the repo root does not exist from this cwd.
        self.assertEqual(cli(self.r, "--strict", "--paths", "Sources/AppCore/B.swift", cwd=self.r / "Sources")[0], 2)

    def test_selection_matching_no_scanned_file_is_usage_error(self):
        self.assertEqual(cli(self.r, "--paths", str(self.r / "docs"))[0], 2)


class Extraction(unittest.TestCase):
    def _tree(self, src):
        r = tree({"App/StackNest/V.swift": src, "Sources/StackNestL10n/Tables/L10n+X.swift": "",
                  "App/StackNest/Localizable.xcstrings": json.dumps({"sourceLanguage": "ja", "strings": {}, "version": "1.0"})})
        old = time.time() - 1000
        os.utime(r / "App/StackNest/V.swift", (old, old))
        return r

    def test_stale_copy_does_not_hide_a_leak(self):
        r = self._tree('para("日本語の段落")\n')
        now = time.time()
        write_sd(r, "Debug/x86_64/V.stringsdata", "App/StackNest/V.swift", [("日本語の段落", 1)], now - 500)  # old build
        write_sd(r, "Debug/arm64/V.stringsdata", "App/StackNest/V.swift", [], now)                           # latest build
        self.assertEqual(kinds(r), ["app-literal"])

    def test_source_newer_than_extraction_is_stale_build(self):
        r = self._tree('Text("削除")\n')
        write_sd(r, "V.stringsdata", "App/StackNest/V.swift", [("削除", 1)], time.time() - 2000)
        self.assertIn("stale-build", kinds(r))
        rc, out = cli(r, "--strict")
        self.assertEqual(rc, 1)
        self.assertIn("stale-build", out)

    def test_never_extracted_source_with_ja_literal_is_stale_build(self):
        r = self._tree('Text("x")\n')
        (r / "App/StackNest/New.swift").write_text('let a = "新規"\n', encoding="utf-8")
        write_sd(r, "V.stringsdata", "App/StackNest/V.swift", [], time.time())
        # The un-extracted literal is also a genuine leak (app-literal); both are expected together.
        self.assertEqual([(f.kind, f.path) for f in lint.run(r)],
                          [("app-literal", "App/StackNest/New.swift"), ("stale-build", "App/StackNest/New.swift")])

    def test_never_extracted_source_without_ja_literal_is_not_flagged(self):
        # A file with no Japanese literal of its own (an English-only helper, a
        # LocalizedStringKey-only parameter passthrough, ...) never produces a .stringsdata entry
        # to begin with, so "never extracted" must not be raised for it (Task S2-A / brief §4).
        r = self._tree('Text("x")\n')
        (r / "App/StackNest/New.swift").write_text('let a = 1\n', encoding="utf-8")
        write_sd(r, "V.stringsdata", "App/StackNest/V.swift", [], time.time())
        self.assertEqual([(f.kind, f.path) for f in lint.run(r)], [])

    def test_touched_file_without_ja_literal_is_not_flagged_stale(self):
        # A previously-extracted App file that no longer has a Japanese literal of its own (e.g.
        # HelpContent+en.swift, whose strings are already English) does not get its empty
        # .stringsdata rewritten by Xcode, so its mtime alone must not trigger stale-build when
        # it is edited later (Task 17 supplement: _has_checked_ja_literal must gate both branches
        # of check_stale, not just the "never extracted" one).
        r = self._tree('Text("x")\n')
        write_sd(r, "V.stringsdata", "App/StackNest/V.swift", [], time.time())
        (r / "App/StackNest/Help.swift").write_text('let a = "hello"\n', encoding="utf-8")
        write_sd(r, "Help.stringsdata", "App/StackNest/Help.swift", [], time.time() - 2000)
        now = time.time()
        os.utime(r / "App/StackNest/Help.swift", (now, now))
        self.assertEqual(kinds(r), [])

    def test_touched_file_with_ja_literal_is_still_flagged_stale(self):
        # The same shape as above, but the file does have a checked Japanese literal: the mtime
        # check must still fire (the fix must not blanket-disable the mtime branch).
        r = self._tree('Text("x")\n')
        write_sd(r, "V.stringsdata", "App/StackNest/V.swift", [], time.time())
        (r / "App/StackNest/Help.swift").write_text('let a = "新規"\n', encoding="utf-8")
        write_sd(r, "Help.stringsdata", "App/StackNest/Help.swift", [("新規", 1)], time.time() - 2000)
        now = time.time()
        os.utime(r / "App/StackNest/Help.swift", (now, now))
        self.assertIn("stale-build", kinds(r))

    def test_never_extracted_source_with_only_ignored_ja_literal_is_not_flagged(self):
        # A Japanese literal that is entirely `l10n:ignore`d (or logger-only) does not count either:
        # it is excluded from every other check the same way, so it must not force a rebuild here.
        r = self._tree('Text("x")\n')
        (r / "App/StackNest/New.swift").write_text('let a = "新規" // l10n:ignore parser token\n', encoding="utf-8")
        write_sd(r, "V.stringsdata", "App/StackNest/V.swift", [], time.time())
        self.assertEqual([(f.kind, f.path) for f in lint.run(r)], [])

    def test_strict_without_extraction_fails_unless_no_app_checks(self):
        r = self._tree('let a = 1\n')
        self.assertEqual(cli(r)[0], 0)                               # report mode: warn and skip
        rc, out = cli(r, "--strict")
        self.assertEqual(rc, 1)
        self.assertIn("no App .stringsdata", out)
        self.assertEqual(cli(r, "--strict", "--no-app-checks")[0], 0)
        # Selecting only non-App files does not need the App build.
        (r / "Sources/AppCore").mkdir(parents=True)
        (r / "Sources/AppCore/A.swift").write_text("let a = 1\n", encoding="utf-8")
        self.assertEqual(cli(r, "--strict", "--paths", str(r / "Sources/AppCore"))[0], 0)


class EmptyTranslations(unittest.TestCase):
    def _app(self, en):
        cat = {"削除": {"localizations": {"en": {"stringUnit": en}}}}
        r = tree({"App/StackNest/V.swift": 'Text("削除")\n', "Sources/StackNestL10n/Tables/L10n+X.swift": "",
                  "App/StackNest/Localizable.xcstrings": json.dumps({"sourceLanguage": "ja", "strings": cat, "version": "1.0"}, ensure_ascii=False)})
        write_sd(r, "V.stringsdata", "App/StackNest/V.swift", [("削除", 1)], time.time() + 10)
        return r

    def test_empty_xcstrings_value_is_app_missing(self):
        self.assertEqual(kinds(self._app({"state": "new", "value": ""})), ["app-missing"])

    def test_japanese_xcstrings_value_is_app_missing(self):
        self.assertEqual(kinds(self._app({"state": "translated", "value": "保存"})), ["app-missing"])

    def test_empty_table_entry_is_swift_missing(self):
        r = tree({"Sources/AppCore/A.swift": 'let s = L10n.text("削除")\n',
                  "Sources/StackNestL10n/Tables/L10n+X.swift": 'extension L10nTable { static let x: [String: L10nEntry] = ["削除": L10nEntry("")] }\n'})
        self.assertEqual(kinds(r), ["swift-missing"])

    def test_empty_web_value_is_web_missing(self):
        r = tree({"Sources/LibraryServer/Resources/web/app.js": "b.textContent = t('閉じる');\n",
                  "Sources/LibraryServer/Resources/web/i18n-en.js": "export const EN = { '閉じる': '' };\n",
                  "Sources/StackNestL10n/Tables/L10n+X.swift": "",
                  "Scripts/l10n-allowlist.txt": "Sources/LibraryServer/Resources/web/i18n-en.js  # dict\n"})
        self.assertEqual(kinds(r), ["web-missing"])


class SpecifierOrder(unittest.TestCase):
    def test_mixed_positional_and_plain(self):
        # Same as Swift's L10n.formatSpecifierSequence: positional first by N, plain ones after.
        self.assertEqual(lint.specifier_sequence("%lld %1$@"), ["%@", "%lld"])
        self.assertEqual(lint.specifier_sequence("%2$@ %lld %1$d %%"), ["%d", "%@", "%lld"])
        self.assertEqual(lint.specifier_sequence("%@ の %lld"), ["%@", "%lld"])


class MergeFragments(unittest.TestCase):
    def _load(self):
        spec = importlib.util.spec_from_file_location("merge", ROOT / "tools" / "l10n" / "merge_fragments.py")
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        return m

    def test_merge_check_and_conflict(self):
        m = self._load()
        cat = {"sourceLanguage": "ja", "strings": {"削除": {}, "閉じる": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Close"}}}}}, "version": "1.0"}
        r = tree({"App/StackNest/Localizable.xcstrings": json.dumps(cat, ensure_ascii=False),
                  "tools/l10n/fragments/U1.json": json.dumps({"削除": {"en": "Delete"}, "閉じる": {"en": "Close"}, "%lld 件": {"plural": {"one": "%lld item", "other": "%lld items"}}}, ensure_ascii=False)})
        self.assertEqual(m.main(["--root", str(r), "--check"]), 1)
        self.assertEqual(m.main(["--root", str(r)]), 0)
        self.assertEqual(m.main(["--root", str(r), "--check"]), 0)
        out = json.loads((r / "App/StackNest/Localizable.xcstrings").read_text(encoding="utf-8"))
        self.assertEqual(out["strings"]["削除"]["localizations"]["en"]["stringUnit"]["value"], "Delete")
        self.assertEqual(out["strings"]["%lld 件"]["localizations"]["en"]["variations"]["plural"]["one"]["stringUnit"]["value"], "%lld item")
        # A second unit translating the same key differently must stop the merge without writing.
        (r / "tools/l10n/fragments/U2.json").write_text(json.dumps({"閉じる": {"en": "Dismiss"}}, ensure_ascii=False), encoding="utf-8")
        before = (r / "App/StackNest/Localizable.xcstrings").read_text(encoding="utf-8")
        self.assertEqual(m.main(["--root", str(r)]), 2)
        self.assertEqual((r / "App/StackNest/Localizable.xcstrings").read_text(encoding="utf-8"), before)


    # G55 S2-C: an English dotted key carries its Japanese value as "ja".
    def _tree_with(self, catalog_strings, *fragments):
        cat = {"sourceLanguage": "ja", "strings": catalog_strings, "version": "1.0"}
        files = {"App/StackNest/Localizable.xcstrings": json.dumps(cat, ensure_ascii=False)}
        for i, frag in enumerate(fragments):
            files[f"tools/l10n/fragments/F{i}.json"] = json.dumps(frag, ensure_ascii=False)
        return tree(files)

    def test_dotted_key_writes_ja_and_en(self):
        m = self._load()
        r = self._tree_with({}, {"settings.tab.labels": {"ja": "ラベル", "en": "Labels"}})
        self.assertEqual(m.main(["--root", str(r)]), 0)
        locs = json.loads((r / "App/StackNest/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]["settings.tab.labels"]["localizations"]
        self.assertEqual(locs["ja"]["stringUnit"]["value"], "ラベル")
        self.assertEqual(locs["en"]["stringUnit"]["value"], "Labels")
        self.assertEqual(m.main(["--root", str(r), "--check"]), 0)

    def test_dotted_key_without_ja_is_rejected(self):
        m = self._load()
        r = self._tree_with({}, {"settings.tab.labels": {"en": "Labels"}})
        self.assertEqual(m.main(["--root", str(r)]), 2)

    def test_ja_on_a_japanese_key_is_rejected(self):
        m = self._load()
        r = self._tree_with({}, {"ラベル": {"ja": "ラベル", "en": "Labels"}})
        self.assertEqual(m.main(["--root", str(r)]), 2)

    def test_ja_conflicts_are_detected(self):
        m = self._load()
        # Two fragments giving the same dotted key different Japanese values.
        r = self._tree_with({}, {"k.a": {"ja": "接続", "en": "Connection"}}, {"k.a": {"ja": "接続先", "en": "Connection"}})
        self.assertEqual(m.main(["--root", str(r)]), 2)
        # The catalog already has a different Japanese value.
        ja = {"stringUnit": {"state": "translated", "value": "接続先"}}
        r = self._tree_with({"k.a": {"localizations": {"ja": ja}}}, {"k.a": {"ja": "接続", "en": "Connection"}})
        before = (r / "App/StackNest/Localizable.xcstrings").read_text(encoding="utf-8")
        self.assertEqual(m.main(["--root", str(r)]), 2)
        self.assertEqual((r / "App/StackNest/Localizable.xcstrings").read_text(encoding="utf-8"), before)


class Mcp(unittest.TestCase):
    def test_g56_mcp_python_japanese_strings(self):
        r = tree({"mcp-stacknest/server.py": 'def f():\n    """一覧を返す"""\n    # コメントは対象外\n    return "ok"\n',
                  "mcp-stacknest/tests/test_x.py": 'x = "テスト"\n',
                  "mcp-stacknest/cli.py": 'y = "上巻"  # l10n:ignore stored value\n'})
        self.assertEqual(kinds(r, app_checks=False), ["mcp-literal"])


if __name__ == "__main__":
    unittest.main()
