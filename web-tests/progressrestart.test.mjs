// SPDX-License-Identifier: MIT
// G26 Codex Important #1: サーバの `/progress` は破損（部分読み）本で「保存済み位置より手前」の
// 書き込みを無視して読書位置を守る。ユーザーが明示的に「最初から」を選んだときだけ
// `restart: true` でその保護を解除する。**`page === 0` から意思を推測してはならない**
// （0 は単に 1 ページ目でもある）ので、意思は必ず明示フィールドで運ばれる必要がある。
// ここでは api.js が body に何を載せるかを固定する（sessiontoken.test.mjs と同じ流儀）。
import { test } from "node:test";
import assert from "node:assert/strict";

const store = new Map();
globalThis.localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
};
globalThis.sessionStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };

const api = await import("../Sources/LibraryServer/Resources/web/api.js");

/// fetch を差し替え、最後に送った JSON body を取り出せるようにする。
function stubFetch() {
    const calls = [];
    globalThis.fetch = async (url, options) => {
        calls.push({ url, options });
        // api() は session token 交換にも fetch を使うため、両方に使える応答を返す。
        return { ok: true, status: 200, json: async () => ({ sessionToken: "S", expiresIn: 1800 }) };
    };
    return calls;
}

function lastProgressBody(calls) {
    const call = [...calls].reverse().find((c) => String(c.url).includes("/progress"));
    assert.ok(call, "/progress へのリクエストが飛んでいない");
    return JSON.parse(call.options.body);
}

test("postProgress: 既定では restart キーを送らない（旧サーバ互換・既定の body 形を変えない）", async () => {
    store.set("stacknest.token", "T");
    api.invalidateSessionToken();
    const calls = stubFetch();

    await api.postProgress("uuid1", 7, 29);

    const body = lastProgressBody(calls);
    assert.equal(body.page, 29);
    assert.ok(!("restart" in body), `restart キーが混ざっている: ${JSON.stringify(body)}`);
});

test("postProgress: restart=true のときだけ restart:true を載せる（「最初から」の意思表示）", async () => {
    store.set("stacknest.token", "T");
    api.invalidateSessionToken();
    const calls = stubFetch();

    await api.postProgress("uuid1", 7, 0, true);

    const body = lastProgressBody(calls);
    assert.equal(body.page, 0);
    assert.equal(body.restart, true);
});

test("postProgress: restart=false を明示しても body は既定形のまま（page 0 でも意思にはならない）", async () => {
    store.set("stacknest.token", "T");
    api.invalidateSessionToken();
    const calls = stubFetch();

    await api.postProgress("uuid1", 7, 0, false);

    const body = lastProgressBody(calls);
    assert.equal(body.page, 0);
    assert.ok(!("restart" in body), `restart キーが混ざっている: ${JSON.stringify(body)}`);
});
