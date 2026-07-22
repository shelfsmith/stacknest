// SPDX-License-Identifier: MIT
import { test } from "node:test";
import assert from "node:assert/strict";
import { scrollbarWidthPx, shouldUpdateScrollbarWidth } from "../Sources/LibraryServer/Resources/web/app.js";

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

// ---- G21 #1 追補: ResizeObserver 再発火時のフィードバックループ防止判定 ---------
// （ResizeObserver 自体・document.body への実際の配線は DOM が無いと検証できないため、
// ここでは「値が変わっていなければ書き込みをスキップする」という純粋な判定ロジックのみを
// 単体テストする。DOM 配線側の検証は本レポートの「目視で確認した内容」を参照。）

test("初回（previousPx=null）は値の内容にかかわらず必ず適用する", () => {
    assert.equal(shouldUpdateScrollbarWidth(0, null), true);
    assert.equal(shouldUpdateScrollbarWidth(15, null), true);
});

test("直近と同じ値なら適用しない（自己書き込みによる再発火を止める）", () => {
    assert.equal(shouldUpdateScrollbarWidth(15, 15), false);
    assert.equal(shouldUpdateScrollbarWidth(0, 0), false);
});

test("直近と異なる値（スクロールバーの出現/消失）なら適用する", () => {
    assert.equal(shouldUpdateScrollbarWidth(15, 0), true); // 出現
    assert.equal(shouldUpdateScrollbarWidth(0, 15), true); // 消失
});
