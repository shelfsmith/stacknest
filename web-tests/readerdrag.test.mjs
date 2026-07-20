// SPDX-License-Identifier: MIT
import { test } from "node:test";
import assert from "node:assert/strict";
import { decideDragSettle } from "../Sources/LibraryServer/Resources/web/reader.js";

const W = 400; // 幅。50% = 200px。FLICK = 500 px/s。

test("前方ドラッグ(50%未達)＋リリース逆ジッタ → 前ページへ誤送りしない(cancel)", () => {
    // trackX=-100（右送り方向へ100pxドラッグ・50%未達）、離す瞬間 +600px/s の逆ジッタ。
    // 旧実装は velocity>+500 で advanceLeft(前ページ) が誤発火した。
    const d = decideDragSettle({ trackX: -100, velocity: 600, width: W, forceCancel: false });
    assert.equal(d.action, "cancel");
});

test("前方ドラッグ(50%超)＋リリース逆ジッタ → 逆ジッタ無視で前方送り(right)", () => {
    // trackX=-250（50%=−200 を超過）、+600 の逆ジッタは無視され距離で確定。
    const d = decideDragSettle({ trackX: -250, velocity: 600, width: W, forceCancel: false });
    assert.equal(d.action, "right");
});

test("真の前方フリック(同符号) → 前方送り(right)", () => {
    // trackX=-80（50%未達）だが velocity=-800（ドラッグ継続方向）でフリック確定。
    const d = decideDragSettle({ trackX: -80, velocity: -800, width: W, forceCancel: false });
    assert.equal(d.action, "right");
    assert.equal(d.flick, true);
});

test("真の後方フリック(同符号) → 後方送り(left)", () => {
    const d = decideDragSettle({ trackX: 80, velocity: 800, width: W, forceCancel: false });
    assert.equal(d.action, "left");
    assert.equal(d.flick, true);
});

test("50%超の後方ドラッグ(低速) → 後方送り(left)", () => {
    const d = decideDragSettle({ trackX: 250, velocity: 50, width: W, forceCancel: false });
    assert.equal(d.action, "left");
});

test("微小ドラッグ＋低速 → cancel", () => {
    const d = decideDragSettle({ trackX: 30, velocity: 100, width: W, forceCancel: false });
    assert.equal(d.action, "cancel");
});

test("forceCancel は常に cancel", () => {
    const d = decideDragSettle({ trackX: -300, velocity: -900, width: W, forceCancel: true });
    assert.equal(d.action, "cancel");
});
