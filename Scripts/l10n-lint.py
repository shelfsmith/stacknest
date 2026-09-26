#!/usr/bin/env python3
"""StackNest のローカライズ漏れ検査（G55）。標準ライブラリのみ。

検出する種類（出力に種類名を出す）:
  swift-literal  Sources（SPM）の Swift で、日本語を含む文字列リテラルが L10n.text/format/plural の第 1 引数でない
  swift-missing  L10n.* の日本語キーが Sources/StackNestL10n/Tables/*.swift の辞書に無い
  app-literal    App の Swift で、日本語リテラルが .stringsdata の抽出キーに無い（ローカライズされない経路）
  app-missing    .stringsdata の日本語キーが Localizable.xcstrings（＋--fragments）に en を持たない
  compare        日本語リテラルが比較の文脈にある（==, !=, hasPrefix( 等, case "…":）
  specifier      キーと英訳の書式指定子が引数の順序どおりに一致しない（Web は {name} の集合）
  web-literal    web/*.js の日本語リテラルが t( の第 1 引数でない／index.html の日本語テキストに data-i18n が無い
  web-missing    t('…')・data-i18n="…" のキーが i18n-en.js に無い

既定は報告モード（終了コード 0）。--strict で 1 件でもあれば終了コード 1。
除外: コメント、ロガー呼び出し（logger. / os_log( / Logger( / console.）、`l10n:ignore` の付いた行
（リテラルの開始行、またはその直前のコメントだけの行）、許可リスト（Scripts/l10n-allowlist.txt）のファイル。
"""

import argparse
import bisect
import fnmatch
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from html.parser import HTMLParser
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

JA_RE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uff66-\uff9f]")

# Same pattern as `L10n.formatSpecifiers` in Sources/StackNestL10n/L10n.swift, with the
# position captured separately so the argument order can be reconstructed.
FORMAT_SPEC_RE = re.compile(
    r"%(?:(\d+)\$)?([-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA])|%%"
)
WEB_PARAM_RE = re.compile(r"\{(\w+)\}")

KINDS = [
    "swift-literal", "swift-missing", "app-literal", "app-missing",
    "compare", "specifier", "web-literal", "web-missing",
]

PH = "\ufffc"  # stands for an interpolation inside a normalised literal

TABLES_DIR = "Sources/StackNestL10n/Tables"
APP_DIR = "App/StackNest"
XCSTRINGS = "App/StackNest/Localizable.xcstrings"
WEB_DIR = "Sources/LibraryServer/Resources/web"
WEB_DICT = WEB_DIR + "/i18n-en.js"
WEB_HTML = WEB_DIR + "/index.html"
ALLOWLIST = "Scripts/l10n-allowlist.txt"
DEFAULT_STRINGSDATA = "App/build/Build/Intermediates.noindex"

IGNORE_MARK = "l10n:ignore"
# Logging lines (brief: `logger.` / `Self.logger.` / `os_log(` / `Logger(`), generalised to the
# logger names this codebase uses (coverLogger, diagLogger, epubLog, …) and JS `console.`.
LOG_LINE_RE = re.compile(
    r"\b\w*(?:[Ll]ogger|[Ll]og)\.(?:debug|info|notice|error|warning|fault|critical|trace|log)\s*\("
    r"|\bos_log\s*\(|\bLogger\s*\(|\bconsole\.\w+\s*\("
)
LOG_CALLEE_RE = re.compile(
    r"(?:^|\.)\w*(?:[Ll]ogger|[Ll]og)\.(?:debug|info|notice|error|warning|fault|critical|trace|log)$"
    r"|(?:^|\.)(?:os_log|Logger)$|^console\.\w+$"
)

SWIFT_L10N_CALLEE_RE = re.compile(r"^L10n\.(?:text|format|plural)$")
JS_T_CALLEE_RE = re.compile(r"^t$")

PLACEHOLDER_RE = r"\x01\d+\x02"
SWIFT_COMPARE_BEFORE_RE = re.compile(
    r"(?:==|!=|\.hasPrefix\(|\.hasSuffix\(|\.contains\(|\.starts\(with:|\.range\(of:)\s*$"
    r"|\bcase\s+(?:" + PLACEHOLDER_RE + r"\s*,\s*)*$"
)
JS_COMPARE_BEFORE_RE = re.compile(
    r"(?:===|!==|==|!=|\.startsWith\(|\.endsWith\(|\.includes\(|\.indexOf\()\s*$"
    r"|\bcase\s+$"
)
SWIFT_COMPARE_AFTER_RE = re.compile(r"^\s*(?:==|!=)")
JS_COMPARE_AFTER_RE = re.compile(r"^\s*(?:===|!==|==|!=)")


@dataclass(frozen=True)
class Finding:
    kind: str
    path: str
    line: int
    text: str


@dataclass
class Literal:
    """A string literal found by a tokenizer."""
    text: str                 # decoded value; interpolations are PH
    line: int                 # 1-based line of the opening quote
    offset: int               # placeholder offset in the owning code buffer
    interpolated: bool = False
    before: str = ""          # code before the literal (comments stripped, literals as placeholders)
    after: str = ""           # code after the literal
    callees: list = field(default_factory=list)  # enclosing call names, innermost first
    first_arg: bool = False   # the literal is the first argument of callees[0]


# ---------------------------------------------------------------------------
# Format specifiers
# ---------------------------------------------------------------------------

def specifier_sequence(s: str) -> list[str]:
    """Specifiers in argument order (`%N$` ordered by N, otherwise left to right), positions stripped, `%%` ignored."""
    items = []
    ordinal = 0
    for m in FORMAT_SPEC_RE.finditer(s):
        if m.group(0) == "%%":
            continue
        ordinal += 1
        pos = int(m.group(1)) if m.group(1) else ordinal
        items.append((pos, len(items), "%" + m.group(2)))
    return [spec for _, _, spec in sorted(items)]


def web_params(s: str) -> set[str]:
    return set(WEB_PARAM_RE.findall(s))


def normalize_key(s: str) -> str:
    """Replace format specifiers with PH and `%%` with `%` so extracted keys compare with literals."""
    return FORMAT_SPEC_RE.sub(lambda m: "%" if m.group(0) == "%%" else PH, s)


def has_ja(s: str) -> bool:
    return bool(JA_RE.search(s))


# ---------------------------------------------------------------------------
# Tokenizers
# ---------------------------------------------------------------------------

class _Scanner:
    """Shared helpers: line lookup and post-processing of code buffers into literal contexts."""

    def __init__(self, src: str):
        self.s = src
        self.n = len(src)
        self._nl = [i for i, c in enumerate(src) if c == "\n"]
        self.literals: list[Literal] = []
        self.top_code = ""

    def line_of(self, i: int) -> int:
        return bisect.bisect_right(self._nl, i - 1) + 1

    def _finish(self, code: str, lits: list[Literal], ends: list[int]) -> None:
        for lit, end in zip(lits, ends):
            lit.before = code[max(0, lit.offset - 400):lit.offset]
            lit.after = code[end:end + 120]
            lit.callees, lit.first_arg = _enclosing_calls(code, lit.offset)

    def _placeholder(self, buf: list[str], pos: int, lit: Literal, lits: list, ends: list) -> None:
        ph = f"\x01{len(self.literals)}\x02"
        lit.offset = pos
        self.literals.append(lit)
        lits.append(lit)
        ends.append(pos + len(ph))
        buf.append(ph)


_CALLEE_RE = re.compile(r"([A-Za-z_$][\w$]*(?:\s*\??\.\s*[A-Za-z_$][\w$]*)*)\s*$")


def _enclosing_calls(code: str, off: int) -> tuple[list[str], bool]:
    """Walk back from `off` to find the enclosing call names (stops at a `{` or `;` scope boundary)."""
    callees: list[str] = []
    first_arg = False
    depth = 0
    j = off - 1
    lo = max(0, off - 4000)
    while j >= lo:
        ch = code[j]
        if ch in ")]}":
            depth += 1
        elif ch in "([{":
            if depth == 0:
                if ch != "(":
                    if ch == "{":
                        break
                    j -= 1
                    continue
                m = _CALLEE_RE.search(code, max(0, j - 200), j)
                name = re.sub(r"\s+", "", m.group(1)).replace("?.", ".") if m else ""
                if not callees:
                    first_arg = code[j + 1:off].strip() == ""
                callees.append(name)
            else:
                depth -= 1
        elif ch == ";" and depth == 0:
            break
        j -= 1
    return callees, first_arg


_SWIFT_OPEN_RE = re.compile(r'(#*)("""|")')
_SWIFT_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


class SwiftScanner(_Scanner):
    """Character state machine: code, // and /* */ (nested) comments, "…", \"\"\"…\"\"\", #"…"#, \\( … )."""

    def scan(self) -> list[Literal]:
        self._code(0, nested=False)
        return self.literals

    def _code(self, i: int, nested: bool) -> int:
        s, n = self.s, self.n
        buf: list[str] = []
        lits: list[Literal] = []
        ends: list[int] = []
        pos = 0
        run = i
        depth = 0

        def flush(upto: int) -> None:
            nonlocal pos
            if upto > run:
                chunk = s[run:upto]
                buf.append(chunk)
                pos += len(chunk)

        while i < n:
            c = s[i]
            if c == "/" and i + 1 < n and s[i + 1] == "/":
                flush(i)
                j = s.find("\n", i)
                i = n if j < 0 else j
                buf.append(" "); pos += 1
                run = i
                continue
            if c == "/" and i + 1 < n and s[i + 1] == "*":
                flush(i)
                i = self._block_comment(i)
                buf.append(" "); pos += 1
                run = i
                continue
            if c == '"' or c == "#":
                m = _SWIFT_OPEN_RE.match(s, i)
                if m and (c == '"' or m.group(1)):
                    flush(i)
                    lit, i = self._string(m.end(), len(m.group(1)), m.group(2) == '"""', i)
                    self._placeholder(buf, pos, lit, lits, ends)
                    pos += len(buf[-1])
                    run = i
                    continue
            if nested:
                if c == "(":
                    depth += 1
                elif c == ")":
                    if depth == 0:
                        flush(i)
                        self._finish("".join(buf), lits, ends)
                        return i + 1
                    depth -= 1
            i += 1
        flush(n)
        code = "".join(buf)
        self._finish(code, lits, ends)
        if not nested:
            self.top_code = code
        return n

    def _block_comment(self, i: int) -> int:
        s, n = self.s, self.n
        depth = 0
        while i < n:
            if s.startswith("/*", i):
                depth += 1; i += 2
            elif s.startswith("*/", i):
                depth -= 1; i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        return n

    def _string(self, i: int, hashes: int, multi: bool, start: int) -> tuple[Literal, int]:
        s, n = self.s, self.n
        close = ('"""' if multi else '"') + "#" * hashes
        esc = "\\" + "#" * hashes
        parts: list[str] = []
        interpolated = False
        while i < n:
            if s.startswith(close, i):
                i += len(close)
                break
            if not multi and s[i] == "\n":
                break  # unterminated; resync at the newline
            if s.startswith(esc, i) and i + len(esc) < n:
                k = i + len(esc)
                ch = s[k]
                if ch == "(":
                    i = self._code(k + 1, nested=True)
                    parts.append(PH)
                    interpolated = True
                    continue
                if ch == "u" and k + 1 < n and s[k + 1] == "{":
                    e = s.find("}", k)
                    try:
                        parts.append(chr(int(s[k + 2:e], 16)))
                    except ValueError:
                        parts.append(s[i:e + 1])
                    i = e + 1
                    continue
                if multi and ch in " \t\n":
                    # line continuation: backslash, optional trailing spaces, newline
                    e = s.find("\n", k)
                    if e >= 0 and s[k:e].strip() == "":
                        i = e + 1
                        continue
                if ch in _SWIFT_ESCAPES:
                    parts.append(_SWIFT_ESCAPES[ch])
                    i = k + 1
                    continue
            parts.append(s[i])
            i += 1
        text = "".join(parts)
        if multi:
            text = _dedent_multiline(text)
        return Literal(text=text, line=self.line_of(start), offset=0, interpolated=interpolated), i


def _dedent_multiline(text: str) -> str:
    """Apply Swift multi-line literal rules: drop the first newline and the closing line, strip its indentation."""
    if text.startswith("\n"):
        text = text[1:]
    lines = text.split("\n")
    indent = lines[-1] if lines and lines[-1].strip() == "" else ""
    if lines and lines[-1].strip() == "":
        lines = lines[:-1]
    return "\n".join(l[len(indent):] if l.startswith(indent) else l.lstrip() for l in lines)


_JS_REGEX_PREV = set("(,=:[!&|?{};") | {""}
_JS_REGEX_WORDS = {"return", "typeof", "case", "do", "else", "in", "of", "void", "yield", "await"}


class JSScanner(_Scanner):
    """Character state machine: code, // and /* */, '…', "…", `…${…}…`, regex literals."""

    def scan(self) -> list[Literal]:
        self._code(0, nested=False)
        return self.literals

    def _code(self, i: int, nested: bool) -> int:
        s, n = self.s, self.n
        buf: list[str] = []
        lits: list[Literal] = []
        ends: list[int] = []
        pos = 0
        run = i
        depth = 0

        def flush(upto: int) -> None:
            nonlocal pos
            if upto > run:
                chunk = s[run:upto]
                buf.append(chunk)
                pos += len(chunk)

        def prev_token() -> str:
            full = ("".join(buf[-8:]) + s[run:i]).rstrip()
            if not full:
                return ""
            m = re.search(r"[A-Za-z_$][\w$]*$", full)
            return m.group(0) if m else full[-1]

        while i < n:
            c = s[i]
            if c == "/" and i + 1 < n and s[i + 1] == "/":
                flush(i)
                j = s.find("\n", i)
                i = n if j < 0 else j
                buf.append(" "); pos += 1
                run = i
                continue
            if c == "/" and i + 1 < n and s[i + 1] == "*":
                flush(i)
                j = s.find("*/", i + 2)
                i = n if j < 0 else j + 2
                buf.append(" "); pos += 1
                run = i
                continue
            if c == "/":
                p = prev_token()
                if p in _JS_REGEX_PREV or p in _JS_REGEX_WORDS:
                    i = self._regex(i)
                    continue
            if c in "'\"`":
                flush(i)
                if c == "`":
                    lit, i = self._template(i + 1, i)
                else:
                    lit, i = self._quoted(i + 1, c, i)
                self._placeholder(buf, pos, lit, lits, ends)
                pos += len(buf[-1])
                run = i
                continue
            if nested:
                if c == "{":
                    depth += 1
                elif c == "}":
                    if depth == 0:
                        flush(i)
                        self._finish("".join(buf), lits, ends)
                        return i + 1
                    depth -= 1
            i += 1
        flush(n)
        code = "".join(buf)
        self._finish(code, lits, ends)
        if not nested:
            self.top_code = code
        return n

    def _regex(self, i: int) -> int:
        s, n = self.s, self.n
        i += 1
        in_class = False
        while i < n and s[i] != "\n":
            c = s[i]
            if c == "\\":
                i += 2
                continue
            if c == "[":
                in_class = True
            elif c == "]":
                in_class = False
            elif c == "/" and not in_class:
                i += 1
                while i < n and (s[i].isalnum() or s[i] == "_"):
                    i += 1
                return i
            i += 1
        return i

    def _escape(self, i: int, parts: list[str]) -> int:
        s = self.s
        ch = s[i + 1] if i + 1 < self.n else ""
        simple = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"', "`": "`", "$": "$", "0": "\0"}
        if ch in simple:
            parts.append(simple[ch]); return i + 2
        if ch == "u":
            m = re.match(r"u\{([0-9a-fA-F]+)\}|u([0-9a-fA-F]{4})", s[i + 1:i + 12])
            if m:
                parts.append(chr(int(m.group(1) or m.group(2), 16))); return i + 1 + m.end()
        if ch == "\n":
            return i + 2
        parts.append(ch)
        return i + 2

    def _quoted(self, i: int, q: str, start: int) -> tuple[Literal, int]:
        s, n = self.s, self.n
        parts: list[str] = []
        while i < n and s[i] != q and s[i] != "\n":
            if s[i] == "\\":
                i = self._escape(i, parts)
                continue
            parts.append(s[i]); i += 1
        if i < n and s[i] == q:
            i += 1
        return Literal(text="".join(parts), line=self.line_of(start), offset=0), i

    def _template(self, i: int, start: int) -> tuple[Literal, int]:
        s, n = self.s, self.n
        parts: list[str] = []
        interpolated = False
        while i < n and s[i] != "`":
            if s[i] == "\\":
                i = self._escape(i, parts)
                continue
            if s.startswith("${", i):
                i = self._code(i + 2, nested=True)
                parts.append(PH)
                interpolated = True
                continue
            parts.append(s[i]); i += 1
        if i < n:
            i += 1
        return Literal(text="".join(parts), line=self.line_of(start), offset=0, interpolated=interpolated), i


class _HTMLCollector(HTMLParser):
    """Collects Japanese text nodes / attributes and data-i18n keys from index.html (comments are skipped)."""

    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
    I18N_ATTRS = ("title", "aria-label", "placeholder")

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, dict]] = []
        self.missing: list[tuple[int, str]] = []   # (line, text) Japanese without a data-i18n* counterpart
        self.keys: list[tuple[int, str]] = []      # (line, key) from data-i18n / data-i18n-<attr>

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs}
        line = self.getpos()[0]
        for k, v in a.items():
            if k == "data-i18n" or (k.startswith("data-i18n-") and k[10:] in self.I18N_ATTRS):
                self.keys.append((line, v))
        for attr in self.I18N_ATTRS:
            if has_ja(a.get(attr, "")) and f"data-i18n-{attr}" not in a:
                self.missing.append((line, f'{attr}="{a[attr]}"'))
        if tag not in self.VOID:
            self.stack.append((tag, a))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID and self.stack:
            self.stack.pop()

    def handle_endtag(self, tag):
        for idx in range(len(self.stack) - 1, -1, -1):
            if self.stack[idx][0] == tag:
                del self.stack[idx:]
                break

    def handle_data(self, data):
        if not has_ja(data) or not self.stack:
            return
        tag, a = self.stack[-1]
        if tag in ("script", "style"):
            return
        if "data-i18n" not in a:
            self.missing.append((self.getpos()[0], data.strip()))


# ---------------------------------------------------------------------------
# Allowlist and file selection
# ---------------------------------------------------------------------------

def _glob_to_re(pat: str) -> re.Pattern:
    out = []
    i = 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out.append("(?:.*/)?"); i += 3
        elif pat.startswith("**", i):
            out.append(".*"); i += 2
        elif pat[i] == "*":
            out.append("[^/]*"); i += 1
        elif pat[i] == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(pat[i])); i += 1
    return re.compile("".join(out) + r"\Z")


class Allowlist:
    def __init__(self, patterns: list[str]):
        self.patterns = patterns
        self._res = [_glob_to_re(p) for p in patterns]

    @classmethod
    def load(cls, root: Path) -> "Allowlist":
        p = root / ALLOWLIST
        pats = []
        if p.is_file():
            for raw in p.read_text(encoding="utf-8").splitlines():
                line = raw.split("#", 1)[0].strip()
                if line:
                    pats.append(line)
        return cls(pats)

    def allows(self, rel: str) -> bool:
        return any(r.match(rel) or fnmatch.fnmatch(rel, p) for r, p in zip(self._res, self.patterns))


class Selection:
    """Restricts findings to --paths (files or directories, relative to root or absolute)."""

    def __init__(self, root: Path, paths):
        self.prefixes = None
        if paths:
            self.prefixes = []
            for p in paths:
                pp = Path(p)
                if pp.is_absolute():
                    try:
                        pp = pp.resolve().relative_to(root.resolve())
                    except ValueError:
                        continue
                self.prefixes.append(pp.as_posix().rstrip("/"))

    def includes(self, rel: str) -> bool:
        if self.prefixes is None:
            return True
        return any(rel == p or rel.startswith(p + "/") or p in ("", ".") for p in self.prefixes)


def _rel(root: Path, p: Path) -> str:
    return p.relative_to(root).as_posix()


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# Dictionaries
# ---------------------------------------------------------------------------

_ENTRY_SINGLE_RE = re.compile(r"\x01(\d+)\x02\s*:\s*L10nEntry\(\s*\x01(\d+)\x02\s*\)")
_ENTRY_PLURAL_RE = re.compile(
    r"\x01(\d+)\x02\s*:\s*L10nEntry\(\s*one\s*:\s*\x01(\d+)\x02\s*,\s*other\s*:\s*\x01(\d+)\x02\s*\)"
)


def load_swift_tables(root: Path) -> dict[str, list[tuple[str, int, list[str]]]]:
    """key -> [(rel path, line, [english forms])] from Sources/StackNestL10n/Tables/*.swift."""
    table: dict[str, list] = {}
    d = root / TABLES_DIR
    if not d.is_dir():
        return table
    for f in sorted(d.glob("*.swift")):
        sc = SwiftScanner(_read(f))
        lits = sc.scan()
        code = sc.top_code
        for m in _ENTRY_PLURAL_RE.finditer(code):
            k, one, other = (lits[int(x)] for x in m.groups())
            table.setdefault(k.text, []).append((_rel(root, f), k.line, [one.text, other.text]))
        for m in _ENTRY_SINGLE_RE.finditer(code):
            k, v = lits[int(m.group(1))], lits[int(m.group(2))]
            table.setdefault(k.text, []).append((_rel(root, f), k.line, [v.text]))
    return table


def _xcstrings_forms(entry: dict) -> list[str]:
    en = (entry or {}).get("localizations", {}).get("en")
    if not en:
        return []
    forms = []
    su = en.get("stringUnit")
    if su and su.get("value") is not None:
        forms.append(su["value"])
    for var in (en.get("variations") or {}).values():
        for v in var.values():
            su = v.get("stringUnit") if isinstance(v, dict) else None
            if su and su.get("value") is not None:
                forms.append(su["value"])
    return forms


def load_xcstrings(root: Path) -> dict[str, list[str]]:
    p = root / XCSTRINGS
    if not p.is_file():
        return {}
    data = json.loads(_read(p))
    return {k: _xcstrings_forms(v) for k, v in data.get("strings", {}).items()}


def _fragment_forms(v) -> list[str]:
    if isinstance(v, dict):
        if "en" in v:
            return [v["en"]]
        if "plural" in v:
            return [v["plural"].get("one", ""), v["plural"].get("other", "")]
    return []


def load_fragments(d) -> dict[str, list[tuple[str, list[str]]]]:
    """key -> [(fragment path, [english forms])]."""
    out: dict[str, list] = {}
    if not d:
        return out
    d = Path(d)
    for f in sorted(d.glob("*.json")):
        for k, v in json.loads(_read(f)).items():
            out.setdefault(k, []).append((f, _fragment_forms(v)))
    return out


def load_web_dict(root: Path) -> tuple[dict[str, tuple[int, list[str]]], bool]:
    """key -> (line, [english forms]) from `export const EN = { … }` in i18n-en.js."""
    p = root / WEB_DICT
    if not p.is_file():
        return {}, False
    sc = JSScanner(_read(p))
    lits = sc.scan()
    code = sc.top_code
    m = re.search(r"\bEN\s*=\s*\{", code)
    out: dict[str, tuple[int, list[str]]] = {}
    if not m:
        return out, True
    body = code[m.end():]
    pair = re.compile(
        r"\x01(\d+)\x02\s*:\s*(?:\x01(\d+)\x02|\{\s*(?:one\s*:\s*\x01(\d+)\x02\s*,\s*other\s*:\s*\x01(\d+)\x02"
        r"|other\s*:\s*\x01(\d+)\x02\s*,\s*one\s*:\s*\x01(\d+)\x02)\s*,?\s*\})"
    )
    for pm in pair.finditer(body):
        k = lits[int(pm.group(1))]
        vals = [lits[int(g)].text for g in pm.groups()[1:] if g is not None]
        out[k.text] = (k.line, vals)
    return out, True


def load_stringsdata(sd_root: Path, root: Path):
    """([(table, key, source, line)], app_emitted) from every *.stringsdata under sd_root.

    `app_emitted` is False when no file came from the App target (e.g. a DerivedData built without
    SWIFT_EMIT_LOC_STRINGS, where only the packages' empty files exist); the App checks are then skipped.

    Format (Xcode 26, SWIFT_EMIT_LOC_STRINGS=YES): {"source": abs path, "tables": {"Localizable":
    [{"key", "comment", "location": {"startingLine", "startingColumn"}}]}, "version": 1}.
    """
    out = []
    app_emitted = False
    for f in sorted(sd_root.rglob("*.stringsdata")):
        try:
            d = json.loads(_read(f))
        except (json.JSONDecodeError, OSError):
            continue
        src = d.get("source", "")
        if d.get("tables") or _source_rel(root.resolve(), src).startswith(APP_DIR + "/"):
            app_emitted = True
        for tname, entries in (d.get("tables") or {}).items():
            for e in entries or []:
                if isinstance(e, dict) and "key" in e:
                    line = (e.get("location") or {}).get("startingLine", 0)
                    out.append((tname, e["key"], src, int(line or 0)))
    return out, app_emitted


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def _line_text(src_lines: list[str], line: int) -> str:
    return src_lines[line - 1] if 0 < line <= len(src_lines) else ""


def _excluded(lit: Literal, src_lines: list[str]) -> bool:
    raw = _line_text(src_lines, lit.line)
    if IGNORE_MARK in raw or LOG_LINE_RE.search(raw):
        return True
    # A comment-only line directly above may carry the mark (for multi-line literals, where the
    # opening line cannot take a trailing comment).
    above = _line_text(src_lines, lit.line - 1).strip()
    if above.startswith("//") and IGNORE_MARK in above:
        return True
    return any(LOG_CALLEE_RE.search(c) for c in lit.callees)


def _short(s: str) -> str:
    s = s.replace("\n", "\\n")
    return s if len(s) <= 120 else s[:117] + "..."


def _is_compare(lit: Literal, before_re, after_re) -> bool:
    return bool(before_re.search(lit.before) or after_re.search(lit.after))


def check_swift_sources(root, files, allow, sel, table_keys) -> list[Finding]:
    out = []
    for f in files:
        rel = _rel(root, f)
        # The dictionaries themselves are only checked by `specifier`.
        if rel.startswith(TABLES_DIR + "/") or allow.allows(rel) or not sel.includes(rel):
            continue
        src = _read(f)
        lines = src.split("\n")
        for lit in SwiftScanner(src).scan():
            if not has_ja(lit.text.replace(PH, "")) or _excluded(lit, lines):
                continue
            shown = _short(lit.text.replace(PH, "\\(…)"))
            if _is_compare(lit, SWIFT_COMPARE_BEFORE_RE, SWIFT_COMPARE_AFTER_RE):
                out.append(Finding("compare", rel, lit.line, shown))
            elif lit.callees and lit.first_arg and SWIFT_L10N_CALLEE_RE.match(lit.callees[0]):
                if lit.interpolated or lit.text not in table_keys:
                    out.append(Finding("swift-missing", rel, lit.line, shown))
            else:
                out.append(Finding("swift-literal", rel, lit.line, shown))
    return out


def check_app(root, files, allow, sel, sd_entries, catalog, fragments) -> list[Finding]:
    """compare (always) and, when .stringsdata is available, app-literal / app-missing."""
    out = []
    # A literal counts as extracted when an entry sits at the same file and line with the same
    # normalised text (entries carry `location.startingLine`); entries without a location match by text.
    root_res = root.resolve()
    extracted_at: set = set()
    extracted_any: set = set()
    for _, k, src, line in sd_entries or []:
        if line:
            extracted_at.add((_source_rel(root_res, src), line, normalize_key(k)))
        else:
            extracted_any.add(normalize_key(k))
    for f in files:
        rel = _rel(root, f)
        src = _read(f)
        lines = src.split("\n")
        allowed = allow.allows(rel) or not sel.includes(rel)
        for lit in SwiftScanner(src).scan():
            if allowed or not has_ja(lit.text.replace(PH, "")) or _excluded(lit, lines):
                continue
            shown = _short(lit.text.replace(PH, "\\(…)"))
            if _is_compare(lit, SWIFT_COMPARE_BEFORE_RE, SWIFT_COMPARE_AFTER_RE):
                out.append(Finding("compare", rel, lit.line, shown))
            elif sd_entries is not None and lit.text not in extracted_any \
                    and (rel, lit.line, lit.text) not in extracted_at:
                out.append(Finding("app-literal", rel, lit.line, shown))
    if sd_entries is None:
        return out
    seen = set()
    for tname, key, src, line in sd_entries:
        if tname != "Localizable" or not has_ja(key):
            continue
        srel = _source_rel(root_res, src)
        # Only the App target's own sources belong to App/StackNest/Localizable.xcstrings.
        if srel and not srel.startswith(APP_DIR + "/") and "/" in srel:
            continue
        if srel and (allow.allows(srel) or not sel.includes(srel)):
            continue
        if not srel and sel.prefixes is not None:
            continue
        if (key, srel) in seen:
            continue
        seen.add((key, srel))
        if catalog.get(key) or any(forms for _, forms in fragments.get(key, [])):
            continue
        out.append(Finding("app-missing", srel or XCSTRINGS, line, _short(key)))
    return out


def _source_rel(root_res: Path, src: str) -> str:
    if not src:
        return ""
    p = Path(src)
    try:
        return p.resolve().relative_to(root_res).as_posix() if p.is_absolute() else p.as_posix()
    except ValueError:
        # e.g. a build of the same repo at another path: keep from App/ onward if present
        s = p.as_posix()
        i = s.find("/" + APP_DIR + "/")
        return s[i + 1:] if i >= 0 else s


def check_specifiers(root, sel, swift_table, catalog, fragments, web_dict) -> list[Finding]:
    out = []
    for key, defs in swift_table.items():
        want = specifier_sequence(key)
        for rel, line, forms in defs:
            if sel.includes(rel) and any(specifier_sequence(v) != want for v in forms):
                out.append(Finding("specifier", rel, line, _short(f"{key} -> {' | '.join(forms)}")))
    if sel.includes(XCSTRINGS):
        for key, forms in catalog.items():
            want = specifier_sequence(key)
            if any(specifier_sequence(v) != want for v in forms):
                out.append(Finding("specifier", XCSTRINGS, 0, _short(f"{key} -> {' | '.join(forms)}")))
    for key, defs in fragments.items():
        want = specifier_sequence(key)
        for f, forms in defs:
            rel = _rel(root, f) if f.resolve().is_relative_to(root.resolve()) else f.as_posix()
            if sel.includes(rel) and any(specifier_sequence(v) != want for v in forms):
                out.append(Finding("specifier", rel, 0, _short(f"{key} -> {' | '.join(forms)}")))
    if sel.includes(WEB_DICT):
        for key, (line, forms) in web_dict.items():
            want = web_params(key)
            if any(web_params(v) != want for v in forms):
                out.append(Finding("specifier", WEB_DICT, line, _short(f"{key} -> {' | '.join(forms)}")))
    return out


def check_web(root, allow, sel, web_dict) -> list[Finding]:
    out = []
    d = root / WEB_DIR
    if not d.is_dir():
        return out
    for f in sorted(d.glob("*.js")):
        rel = _rel(root, f)
        if allow.allows(rel) or not sel.includes(rel):
            continue
        src = _read(f)
        lines = src.split("\n")
        for lit in JSScanner(src).scan():
            if not has_ja(lit.text.replace(PH, "")) or _excluded(lit, lines):
                continue
            shown = _short(lit.text.replace(PH, "${…}"))
            if _is_compare(lit, JS_COMPARE_BEFORE_RE, JS_COMPARE_AFTER_RE):
                out.append(Finding("compare", rel, lit.line, shown))
            elif lit.callees and lit.first_arg and JS_T_CALLEE_RE.match(lit.callees[0]):
                if lit.interpolated or lit.text not in web_dict:
                    out.append(Finding("web-missing", rel, lit.line, shown))
            else:
                out.append(Finding("web-literal", rel, lit.line, shown))
    html = root / WEB_HTML
    rel = WEB_HTML
    if html.is_file() and not allow.allows(rel) and sel.includes(rel):
        src = _read(html)
        lines = src.split("\n")
        col = _HTMLCollector()
        col.feed(src)
        col.close()
        for line, text in col.missing:
            if IGNORE_MARK not in _line_text(lines, line):
                out.append(Finding("web-literal", rel, line, _short(text)))
        for line, key in col.keys:
            if has_ja(key) and key not in web_dict:
                out.append(Finding("web-missing", rel, line, _short(key)))
    return out


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

def _swift_files(d: Path) -> list[Path]:
    return sorted(p for p in d.rglob("*.swift") if p.is_file()) if d.is_dir() else []


def run(root: Path, paths=None, fragments=None, stringsdata_root=None, warn=None) -> list[Finding]:
    """Run every check under `root` and return the findings (sorted by kind, path, line)."""
    root = Path(root)
    warn = warn or (lambda msg: None)
    allow = Allowlist.load(root)
    sel = Selection(root, paths)

    swift_table = load_swift_tables(root)
    catalog = load_xcstrings(root)
    frags = load_fragments(fragments)
    web_dict, has_web_dict = load_web_dict(root)

    findings: list[Finding] = []
    findings += check_swift_sources(root, _swift_files(root / "Sources"), allow, sel, swift_table)

    app_files = _swift_files(root / APP_DIR)
    if app_files:
        sd_root = Path(stringsdata_root) if stringsdata_root else root / DEFAULT_STRINGSDATA
        if not sd_root.is_absolute() and stringsdata_root:
            sd_root = Path.cwd() / sd_root
        sd_entries, has_sd = load_stringsdata(sd_root, root) if sd_root.is_dir() else ([], False)
        if not has_sd:
            warn(f"warning: no App .stringsdata under {sd_root}; app-literal / app-missing were skipped "
                 f"(build the App with SWIFT_EMIT_LOC_STRINGS=YES first)")
            sd_entries = None
        findings += check_app(root, app_files, allow, sel, sd_entries, catalog, frags)

    findings += check_specifiers(root, sel, swift_table, catalog, frags, web_dict)
    if (root / WEB_DIR).is_dir() and not has_web_dict:
        warn(f"warning: {WEB_DICT} not found; every t()/data-i18n key counts as web-missing")
    findings += check_web(root, allow, sel, web_dict)
    return sorted(set(findings), key=lambda f: (KINDS.index(f.kind), f.path, f.line, f.text))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="StackNest localization leak lint (G55).")
    ap.add_argument("--strict", action="store_true", help="exit 1 if there is any finding")
    ap.add_argument("--paths", nargs="+", metavar="P",
                    help="only report findings in these files/directories (include your fragment file "
                         "and dictionary file to check their specifiers)")
    ap.add_argument("--fragments", metavar="DIR",
                    help="treat keys in DIR/*.json (tools/l10n/fragments) as translated")
    ap.add_argument("--stringsdata-root", metavar="DIR", default=None,
                    help=f"where the App build put *.stringsdata (default: {DEFAULT_STRINGSDATA})")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[1]), help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    root = Path(args.root)
    findings = run(root, paths=args.paths, fragments=args.fragments,
                   stringsdata_root=args.stringsdata_root,
                   warn=lambda m: print(m, file=sys.stderr))
    counts = {k: 0 for k in KINDS}
    for f in findings:
        counts[f.kind] += 1

    if args.json:
        print(json.dumps({"counts": counts, "total": len(findings),
                          "findings": [asdict(f) for f in findings]}, ensure_ascii=False, indent=2))
    else:
        for f in findings[:200]:
            print(f"{f.kind}\t{f.path}:{f.line}\t{f.text}")
        if len(findings) > 200:
            print(f"... {len(findings) - 200} more (use --json for all)")
        print("counts: " + ", ".join(f"{k}={v}" for k, v in counts.items()) + f", total={len(findings)}")
    return 1 if args.strict and findings else 0


if __name__ == "__main__":
    sys.exit(main())
