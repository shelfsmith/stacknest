// SPDX-License-Identifier: MIT
// G55 S2-C: api() は画面の言語（i18n.js の LANG）を Accept-Language に載せる。
// `?lang=en` で上書きしたときに、サーバのエラー文もブラウザの言語ではなく画面の言語になるようにするため。
import { test } from "node:test";
import assert from "node:assert/strict";

globalThis.localStorage = { getItem: () => "TOKEN", setItem: () => {}, removeItem: () => {} };
globalThis.sessionStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };

const api = await import("../Sources/LibraryServer/Resources/web/api.js");
const i18n = await import("../Sources/LibraryServer/Resources/web/i18n.js");

function stubFetch() {
    const calls = [];
    globalThis.fetch = async (url, options) => {
        calls.push({ url, options });
        return { ok: true, status: 200, json: async () => ({}) };
    };
    return calls;
}

test("api: Accept-Language は LANG に従う（en / ja）", async () => {
    const saved = i18n.LANG;
    try {
        for (const lang of ["en", "ja"]) {
            i18n.__setLangForTesting(lang);
            const calls = stubFetch();
            await api.api("/libraries");
            assert.equal(calls[0].options.headers["Accept-Language"], lang);
            assert.equal(calls[0].options.headers.Authorization, "Bearer TOKEN");
        }
    } finally {
        i18n.__setLangForTesting(saved);
    }
});

test("api: 呼び出し側のヘッダは保たれ、明示した Accept-Language は上書きしない", async () => {
    const saved = i18n.LANG;
    try {
        i18n.__setLangForTesting("en");
        const calls = stubFetch();
        await api.api("/x", { method: "POST", headers: { "Content-Type": "application/json" } });
        assert.equal(calls[0].options.headers["Content-Type"], "application/json");
        assert.equal(calls[0].options.headers["Accept-Language"], "en");

        const calls2 = stubFetch();
        await api.api("/x", { headers: { "Accept-Language": "ja" } });
        assert.equal(calls2[0].options.headers["Accept-Language"], "ja");
    } finally {
        i18n.__setLangForTesting(saved);
    }
});
