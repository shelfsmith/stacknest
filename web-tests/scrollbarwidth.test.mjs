// SPDX-License-Identifier: MIT
import { test } from "node:test";
import assert from "node:assert/strict";
import { scrollbarWidthPx } from "../Sources/LibraryServer/Resources/web/app.js";

test("常時表示スクロールバー環境では差分を返す", () => {
    assert.equal(scrollbarWidthPx({ innerWidth: 1200 }, { clientWidth: 1185 }), 15);
});

test("オーバーレイスクロールバー環境では 0", () => {
    assert.equal(scrollbarWidthPx({ innerWidth: 1200 }, { clientWidth: 1200 }), 0);
});

test("負値やおかしな値は 0 に丸める（レイアウト前・拡大縮小時の保険）", () => {
    assert.equal(scrollbarWidthPx({ innerWidth: 1000 }, { clientWidth: 1200 }), 0);
    assert.equal(scrollbarWidthPx({ innerWidth: 0 }, { clientWidth: 0 }), 0);
});

test("異常に大きい差分は無視する（0 を返す＝従来挙動へフォールバック）", () => {
    assert.equal(scrollbarWidthPx({ innerWidth: 1200 }, { clientWidth: 200 }), 0);
});
