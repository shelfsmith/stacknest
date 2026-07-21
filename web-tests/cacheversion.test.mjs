// SPDX-License-Identifier: MIT
// 最終レビュー Finding 4: G4d 層2（web 版キーページキャッシュの版鍵化）は native 側にはテスト
// スイートがある一方、web/ 側（reader.js の normalizeVersion / idb.js の cacheKey）にはゼロだった。
// readerdrag.test.mjs と同じ流儀（node --test が直接 ESM import して純関数を検証）で埋める。
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeVersion } from "../Sources/LibraryServer/Resources/web/reader.js";
import { cacheKey } from "../Sources/LibraryServer/Resources/web/idb.js";

// ---- normalizeVersion ----------------------------------------------------

test("normalizeVersion: クォート付き ETag はクォートを剥がして返す", () => {
    assert.equal(normalizeVersion('"abc123"'), "abc123");
});

test("normalizeVersion: クォート無しの素文字列はそのまま通す（防御的・後方互換パス）", () => {
    assert.equal(normalizeVersion("abc123"), "abc123");
});

test("normalizeVersion: 非文字列/undefined はクラッシュせず安全にそのまま通す", () => {
    assert.equal(normalizeVersion(undefined), undefined);
    assert.equal(normalizeVersion(null), null);
    assert.equal(normalizeVersion(42), 42);
});

// ---- cacheKey --------------------------------------------------------------

test("cacheKey: version フィールドがキーに含まれる", () => {
    const k = cacheKey("uuid1", 1, 0, null, "v1");
    assert.ok(k.includes("v1"));
});

test("cacheKey: 異なる version は異なるキーを生成する（版が変われば別キャッシュ枠になる）", () => {
    const k1 = cacheKey("uuid1", 1, 0, null, "v1");
    const k2 = cacheKey("uuid1", 1, 0, null, "v2");
    assert.notEqual(k1, k2);
});

test("cacheKey: version 省略時は旧フォーマット（末尾フィールドが空文字）と一致する", () => {
    const withUndefinedVersion = cacheKey("uuid1", 1, 0, null, undefined);
    const legacyFormat = "uuid1|1|0|full|";
    assert.equal(withUndefinedVersion, legacyFormat);
});
