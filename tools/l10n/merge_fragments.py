#!/usr/bin/env python3
"""翻訳の断片（tools/l10n/fragments/*.json）を App/StackNest/Localizable.xcstrings に取り込む（G55）。

断片の形式:
  { "日本語キー": { "en": "English" } }
  { "日本語キー": { "plural": { "one": "…", "other": "…" } } }
  { "english.dotted.key": { "ja": "日本語", "en": "English" } }   ← G55 S2-C

英語のドット区切りキー（同じ日本語を文脈ごとに訳し分けるため、呼び出し側で
`String(localized: "key", defaultValue: "日本語")` としたもの）は、`ja` に呼び出し側の
defaultValue と同じ日本語を必ず書く。`ja` と `en` の両方の localization を書く（`ja` が無いと
原文言語の表で値がキーそのものになり、日本語 UI にキーが出うる）。日本語のキーに `ja` は書けない。

既存の英訳と食い違う場合、または 2 つの断片が同じキーを別訳にしている場合は、何も書かずに
終了コード 2 で止まる。`--check` は書き込まず、変更が必要なら終了コード 1 を返す。
標準ライブラリのみ。
"""
from __future__ import annotations   # `str | None` on Python 3.9 (macOS /usr/bin/python3)

import argparse
import copy
import json
import re
import sys
from pathlib import Path

XCSTRINGS = "App/StackNest/Localizable.xcstrings"
FRAGMENTS = "tools/l10n/fragments"

JA_RE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uff66-\uff9f]")
# English dotted keys such as `settings.tab.labels` (G55 S2-C).
DOTTED_KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+$")


def _unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def fragment_to_en(v) -> dict:
    """Fragment value -> xcstrings `localizations.en` object."""
    if not isinstance(v, dict):
        raise ValueError(f"fragment value must be an object, got {v!r}")
    if "en" in v:
        return _unit(v["en"])
    if "plural" in v:
        p = v["plural"]
        return {"variations": {"plural": {"one": _unit(p["one"]), "other": _unit(p["other"])}}}
    raise ValueError(f"fragment value needs 'en' or 'plural': {v!r}")


def fragment_to_ja(k: str, v) -> str | None:
    """Fragment value -> the Japanese source value for a non-Japanese key (None for Japanese keys)."""
    ja = v.get("ja") if isinstance(v, dict) else None
    if JA_RE.search(k):
        if ja is not None:
            raise ValueError("'ja' is only for non-Japanese keys (a Japanese key is its own value)")
        return None
    if ja is None:
        if DOTTED_KEY_RE.match(k):
            raise ValueError("a dotted key needs 'ja' (the call site's defaultValue)")
        return None
    if not isinstance(ja, str) or not ja.strip():
        raise ValueError(f"'ja' must be a non-empty string, got {ja!r}")
    return ja


def _ja_value(loc) -> str | None:
    return (loc or {}).get("stringUnit", {}).get("value")


def _signature(en: dict):
    """Comparable form of an en localization (ignores `state`)."""
    if not en:
        return None
    if "variations" in en:
        pl = en["variations"].get("plural", {})
        return ("plural", tuple(sorted((k, v.get("stringUnit", {}).get("value")) for k, v in pl.items())))
    return ("text", en.get("stringUnit", {}).get("value"))


def load_fragments(d: Path) -> tuple[dict, list[str]]:
    """key -> (en object, fragment file name, ja value or None); plus conflicts between fragments."""
    merged: dict = {}
    errors: list[str] = []
    for f in sorted(d.glob("*.json")):
        data = json.loads(f.read_text(encoding="utf-8"))
        for k, v in data.items():
            try:
                en = fragment_to_en(v)
                ja = fragment_to_ja(k, v)
            except (ValueError, KeyError, TypeError) as e:
                errors.append(f"{f.name}: {k!r}: {e}")
                continue
            if k in merged and (_signature(merged[k][0]), merged[k][2]) != (_signature(en), ja):
                errors.append(f"{k!r}: {merged[k][1]} and {f.name} translate it differently")
                continue
            merged.setdefault(k, (en, f.name, ja))
    return merged, errors


def merge(catalog: dict, fragments: dict) -> tuple[dict, list[str]]:
    out = copy.deepcopy(catalog)
    strings = out.setdefault("strings", {})
    errors: list[str] = []
    for k, (en, src, ja) in sorted(fragments.items()):
        entry = strings.setdefault(k, {})
        locs = entry.setdefault("localizations", {})
        cur = locs.get("en")
        if cur and _signature(cur) != _signature(en):
            errors.append(f"{k!r}: {src} says {_signature(en)!r} but the catalog has {_signature(cur)!r}")
            continue
        cur_ja = _ja_value(locs.get("ja"))
        if ja is not None and cur_ja is not None and cur_ja != ja:
            errors.append(f"{k!r}: {src} says ja={ja!r} but the catalog has ja={cur_ja!r}")
            continue
        if not cur:
            locs["en"] = en
        if ja is not None and cur_ja is None:
            locs["ja"] = _unit(ja)
    out["strings"] = dict(sorted(strings.items()))
    return out, errors


def dump(catalog: dict) -> str:
    # Xcode writes `"key" : value` with two-space indentation and sorted keys.
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Merge tools/l10n/fragments/*.json into Localizable.xcstrings.")
    ap.add_argument("--check", action="store_true", help="do not write; exit 1 if a change is needed")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[2]), help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    root = Path(args.root)
    cat_path = root / XCSTRINGS
    catalog = json.loads(cat_path.read_text(encoding="utf-8"))
    fragments, errors = load_fragments(root / FRAGMENTS)
    merged, merge_errors = merge(catalog, fragments)
    errors += merge_errors
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        print(f"{len(errors)} conflict(s); nothing written", file=sys.stderr)
        return 2

    changed = merged != catalog
    if args.check:
        print("changes needed" if changed else "up to date")
        return 1 if changed else 0
    if changed:
        cat_path.write_text(dump(merged), encoding="utf-8")
    print(f"merged {len(fragments)} fragment key(s); {'written' if changed else 'no change'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
