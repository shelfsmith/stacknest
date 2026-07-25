// SPDX-License-Identifier: MIT
// G23 (#9/#10): URL クエリへ載せるトークンを短命セッショントークンへ置き換えた。
// api.js の交換ロジック（ensureSessionToken / currentSessionToken / invalidateSessionToken）を
// fetch と localStorage をスタブして検証する。cacheversion.test.mjs と同じ流儀（ESM 直 import）。
import { test } from "node:test";
import assert from "node:assert/strict";

// ---- ブラウザ API のスタブ（import より前に用意する） ----------------------
const store = new Map();
globalThis.localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
};
globalThis.sessionStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };

const api = await import("../Sources/LibraryServer/Resources/web/api.js");

/// fetch を差し替えて呼び出し回数と最後のリクエストを記録する。
function stubFetch(handler) {
    const calls = [];
    globalThis.fetch = async (url, options) => {
        calls.push({ url, options });
        return handler(url, options);
    };
    return calls;
}

function jsonResponse(body, ok = true) {
    return { ok, json: async () => body };
}

test("ensureSessionToken: POST /api/v1/session を Authorization ヘッダ付きで叩く", async () => {
    store.set("stacknest.token", "PERSISTENT");
    api.invalidateSessionToken();
    const calls = stubFetch(() => jsonResponse({ sessionToken: "SESS-1", expiresIn: 1800 }));

    const token = await api.ensureSessionToken();

    assert.equal(token, "SESS-1");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "/api/v1/session");
    assert.equal(calls[0].options.method, "POST");
    // 永続トークンはヘッダでのみ送る（URL には載せない）。
    assert.equal(calls[0].options.headers.Authorization, "Bearer PERSISTENT");
});

test("ensureSessionToken: 2 回目はキャッシュを返し再交換しない", async () => {
    store.set("stacknest.token", "PERSISTENT");
    api.invalidateSessionToken();
    const calls = stubFetch(() => jsonResponse({ sessionToken: "SESS-2", expiresIn: 1800 }));

    await api.ensureSessionToken();
    const second = await api.ensureSessionToken();

    assert.equal(second, "SESS-2");
    assert.equal(calls.length, 1, "交換は 1 回だけ");
    assert.equal(api.currentSessionToken(), "SESS-2");
});

test("ensureSessionToken: 同時呼び出しは 1 本の交換にまとまる", async () => {
    store.set("stacknest.token", "PERSISTENT");
    api.invalidateSessionToken();
    const calls = stubFetch(async () => {
        await new Promise((r) => setTimeout(r, 10));
        return jsonResponse({ sessionToken: "SESS-3", expiresIn: 1800 });
    });

    const [a, b, c] = await Promise.all([
        api.ensureSessionToken(), api.ensureSessionToken(), api.ensureSessionToken(),
    ]);

    assert.equal(a, "SESS-3");
    assert.equal(b, "SESS-3");
    assert.equal(c, "SESS-3");
    assert.equal(calls.length, 1, "並行呼び出しでも交換は 1 回");
});

test("invalidateSessionToken: 破棄すると次回は再交換する", async () => {
    store.set("stacknest.token", "PERSISTENT");
    api.invalidateSessionToken();
    let n = 0;
    const calls = stubFetch(() => jsonResponse({ sessionToken: `SESS-${++n}`, expiresIn: 1800 }));

    const first = await api.ensureSessionToken();
    api.invalidateSessionToken();
    assert.equal(api.currentSessionToken(), null);
    const second = await api.ensureSessionToken();

    assert.notEqual(first, second);
    assert.equal(calls.length, 2);
});

test("ensureSessionToken: 交換失敗（非 2xx）では null を返し例外を投げない", async () => {
    store.set("stacknest.token", "PERSISTENT");
    api.invalidateSessionToken();
    stubFetch(() => jsonResponse({}, false));

    assert.equal(await api.ensureSessionToken(), null);
    assert.equal(api.currentSessionToken(), null);
});

test("ensureSessionToken: fetch 自体が失敗しても null を返す（呼び出し側を壊さない）", async () => {
    store.set("stacknest.token", "PERSISTENT");
    api.invalidateSessionToken();
    globalThis.fetch = async () => { throw new Error("network down"); };

    assert.equal(await api.ensureSessionToken(), null);
});

test("交換失敗後もリトライできる（promise が残らない）", async () => {
    store.set("stacknest.token", "PERSISTENT");
    api.invalidateSessionToken();
    globalThis.fetch = async () => { throw new Error("network down"); };
    assert.equal(await api.ensureSessionToken(), null);

    const calls = stubFetch(() => jsonResponse({ sessionToken: "SESS-RETRY", expiresIn: 1800 }));
    assert.equal(await api.ensureSessionToken(), "SESS-RETRY");
    assert.equal(calls.length, 1);
});
