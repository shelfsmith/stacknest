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

function makeCtx(opts = {}) {
    const calls = [];
    const putCalls = [];
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
        // review follow-up Finding 1: fetchPageBlob は { blob, noStore } を返す契約に変更された
        // （以前は Blob 単体）。noStore は opts.noStore で外から差し込めるようにする。
        fetchPageBlob: async (uuid, bookId, apiIndex, maxw, signal, version) => {
            calls.push({ uuid, bookId, apiIndex, maxw, signal, version });
            return { blob: new Blob(["x"]), noStore: opts.noStore ?? false };
        },
        // review follow-up Finding 1 のテスト容易化フック: 実 IndexedDB を経由せず
        // 「putPage が呼ばれたか」を直接観測する。
        putPage: async (key, book, blob) => { putCalls.push({ key, book, blob }); },
    };
    return { ctx, calls, putCalls };
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

// ---- review follow-up Finding 1: no-store 応答は IndexedDB(putPage) に残さない ------------
//
// 失敗シナリオ（このテストが再現する不具合そのもの）: リーダーが version A で開く → 外部で
// relink されて version が B に切り替わる → prefetch が `/pages/3?v=A` を取りに行く →
// サーバは 200 + `Cache-Control: no-store` で B のバイトを返す（現在の正しいバイト・古い版キー
// への焼き付け防止のため no-store）。このとき putPage をスキップしなければ、B のバイトが
// IndexedDB の旧版キー `...|vA` の下に固定され、後で A へ relink し戻ったときに vA キーが
// ヒットして B のページが（7日 purge まで）表示され続ける。

test("_fetch (requestPage 経由): noStore=true の応答は putPage に一切渡さない", async () => {
    const { ctx, putCalls } = makeCtx({ noStore: true });
    const engine = new PrefetchEngine(ctx);
    const blob = await engine.requestPage(5);
    assert.ok(blob instanceof Blob, "no-store でもバイト自体は表示用に返す");
    assert.equal(putCalls.length, 0,
        "noStore=true の応答が putPage に渡っている — 誤った版キーの下へバイトが固定される（relink 巻き戻し時に stale 表示が再発する）");
});

test("requestFullResolution: noStore=true の応答は putPage に一切渡さない", async () => {
    const { ctx, putCalls } = makeCtx({ noStore: true });
    const engine = new PrefetchEngine(ctx);
    const blob = await engine.requestFullResolution(5);
    assert.ok(blob instanceof Blob, "no-store でもバイト自体は表示用に返す");
    assert.equal(putCalls.length, 0,
        "noStore=true の応答が putPage に渡っている — 誤った版キーの下へバイトが固定される（relink 巻き戻し時に stale 表示が再発する）");
});

test("_fetch (requestPage 経由): noStore=false（通常の版一致）応答は today 通り putPage に渡る", async () => {
    const { ctx, putCalls } = makeCtx({ noStore: false });
    const engine = new PrefetchEngine(ctx);
    await engine.requestPage(5);
    assert.equal(putCalls.length, 1,
        "cacheable な応答まで putPage をスキップしてしまうと、正規のページも二度とキャッシュされずアプリ内キャッシュの効果が失われる（性能退行）");
});

test("requestFullResolution: noStore=false（通常の版一致）応答は today 通り putPage に渡る", async () => {
    const { ctx, putCalls } = makeCtx({ noStore: false });
    const engine = new PrefetchEngine(ctx);
    await engine.requestFullResolution(5);
    assert.equal(putCalls.length, 1,
        "cacheable な応答まで putPage をスキップしてしまうと、正規のページも二度とキャッシュされずアプリ内キャッシュの効果が失われる（性能退行）");
});
