// SPDX-License-Identifier: MIT
// レビュー指摘の穴埋め: cacheversion.test.mjs は pageQuery という純関数だけを検証しており、
// prefetch.js 側の実際の呼び出し（requestFullResolution / _fetch 経由の requestPage）が
// ctx.version を fetchPageBlob に渡し忘れても検知できなかった（今回見つかった実バグそのもの）。
// ここでは PrefetchEngine を実際に駆動し、fetchPageBlob に渡る引数を偽実装で捕捉して
// version が両経路で欠落していないことを直接アサートする。
//
// indexedDB 依存について: idb.js の getPage/putPage/evictToLimit 等は openDB() の失敗を
// 内部の try/catch で握りつぶし、getPage は null（=cache miss）、putPage/evictToLimit は
// no-op として振る舞う設計になっている（openDB() 内で `indexedDB.open` を呼ぶ際、Node に
// グローバル indexedDB が存在しないと ReferenceError が Promise executor 内で同期的に投げられ、
// Promise が自動的に reject されるだけで例外は外に漏れない）。そのため本テストは
// globalThis.indexedDB のスタブや prefetch.js/idb.js への改変を一切必要としない
// （readerdrag.test.mjs / cacheversion.test.mjs と同じく node --test が直接 ESM import する
// だけで足りる、最も軽い経路）。常に cache miss → 実 fetch 経路を通る、という前提で
// フェッチ引数を検証する。
import { test } from "node:test";
import assert from "node:assert/strict";
import { PrefetchEngine } from "../Sources/LibraryServer/Resources/web/prefetch.js";

function makeCtx() {
    const calls = [];
    const ctx = {
        uuid: "uuid1",
        bookId: 42,
        pageCount: 100,
        maxw: 1600,
        book: "book1",
        version: "etag-v1",
        tier3Enabled: false,
        cacheLimitBytes: 1e9,
        // ここで実引数をそのまま記録する。version 位置(第6引数)が undefined のまま
        // 呼ばれていないかを後でアサートする。
        fetchPageBlob: async (uuid, bookId, apiIndex, maxw, signal, version) => {
            calls.push({ uuid, bookId, apiIndex, maxw, signal, version });
            return new Blob(["x"]);
        },
    };
    return { ctx, calls };
}

test("requestFullResolution: fetchPageBlob に ctx.version が渡る（全解像度パス）", async () => {
    const { ctx, calls } = makeCtx();
    const engine = new PrefetchEngine(ctx);
    const blob = await engine.requestFullResolution(5);
    assert.ok(blob instanceof Blob);
    assert.equal(calls.length, 1, "fetchPageBlob が1回呼ばれること");
    assert.equal(calls[0].apiIndex, 5);
    assert.equal(
        calls[0].version,
        "etag-v1",
        "requestFullResolution が ctx.version を fetchPageBlob に渡していない（HTTP キャッシュ stale 再発の温床）"
    );
});

test("requestPage → _fetch 経由: fetchPageBlob に ctx.version が渡る（通常ページ要求パス）", async () => {
    const { ctx, calls } = makeCtx();
    const engine = new PrefetchEngine(ctx);
    const blob = await engine.requestPage(5);
    assert.ok(blob instanceof Blob);
    assert.equal(calls.length, 1, "fetchPageBlob が1回呼ばれること");
    assert.equal(calls[0].apiIndex, 5);
    assert.equal(
        calls[0].version,
        "etag-v1",
        "_fetch (requestPage 経由) が ctx.version を fetchPageBlob に渡していない（HTTP キャッシュ stale 再発の温床）"
    );
});

test("requestPage: version が変われば別 book/version でも都度 fetchPageBlob に渡る", async () => {
    const { ctx, calls } = makeCtx();
    ctx.version = "etag-v2";
    const engine = new PrefetchEngine(ctx);
    await engine.requestPage(7);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].version, "etag-v2");
});
