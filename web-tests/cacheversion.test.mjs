// SPDX-License-Identifier: MIT
// 最終レビュー Finding 4: G4d 層2（web 版キーページキャッシュの版鍵化）は native 側にはテスト
// スイートがある一方、web/ 側（reader.js の normalizeVersion / idb.js の cacheKey）にはゼロだった。
// readerdrag.test.mjs と同じ流儀（node --test が直接 ESM import して純関数を検証）で埋める。
import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeVersion } from "../Sources/LibraryServer/Resources/web/reader.js";
import { cacheKey } from "../Sources/LibraryServer/Resources/web/idb.js";
import { pageQuery } from "../Sources/LibraryServer/Resources/web/api.js";

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

// ---- pageQuery（HTTP キャッシュ追随修正・G4d 見落とし fix） -----------------
// ページ画像は Cache-Control: immutable の長期キャッシュ対象なのに、URL がバージョンレスだと
// relink 後もブラウザの HTTP キャッシュが古いバイトを immutable として返し続け、それが新しい
// IndexedDB バージョンキーの下に固定されてしまう（stale が sticky になる）。
// pageQuery が組み立てる URL クエリの v= は cacheKey が使う version と同じ値でなければならない
// （ここがずれると「半分だけ版管理された」状態になり本 bug が再発する）。

test("pageQuery: version があれば ?v= を付与し、cacheKey と同じ version 文字列を運ぶ", () => {
    const version = "etag-abc";
    const q = pageQuery(1600, version);
    assert.match(q, /\bv=etag-abc\b/);
    // URL から取り出した v= の値がそのまま cacheKey に渡す version と一致することを確認
    // （デコードしても崩れないことも含めて確認する）。
    const parsed = new URLSearchParams(q.replace(/^\?/, ""));
    assert.equal(parsed.get("v"), version);
    const k = cacheKey("uuid1", 1, 0, 1600, parsed.get("v"));
    assert.equal(k, cacheKey("uuid1", 1, 0, 1600, version));
});

test("pageQuery: version は URL エンコードされる（ETag に記号が含まれても壊れない）", () => {
    const version = 'w/"abc 123"';
    const q = pageQuery(null, version);
    const parsed = new URLSearchParams(q.replace(/^\?/, ""));
    assert.equal(parsed.get("v"), version);   // デコード後は元の文字列に戻る
});

test("pageQuery: maxw のみ（version なし）は today の挙動どおり v= を付けない", () => {
    const q = pageQuery(1600, undefined);
    assert.equal(q, "?maxw=1600");
    assert.ok(!q.includes("v="));
});

test("pageQuery: version なしフォールバック — maxw も version も無ければ空文字（原寸・旧挙動）", () => {
    assert.equal(pageQuery(undefined, undefined), "");
    assert.equal(pageQuery(null, null), "");
    assert.equal(pageQuery(0, null), "");
});

test("pageQuery: 版が変わればテスト失敗するはずのガード — v= が落ちていたら検知できる", () => {
    // このテストは「実装が version を落として旧 URL 形に戻った」場合に必ず失敗させるための
    // 明示ガード（fetchPageBlob 自体は DOM Response が要るためここでは URL 生成のみ検証）。
    const q = pageQuery(1600, "v2");
    assert.ok(q.includes("v=v2"), "version が URL から脱落しています（HTTP キャッシュ stale 再発の温床）");
});
