// SPDX-License-Identifier: MIT
// G54-S3d: テキスト EPUB の「画像 1 枚だけの章」の判定と、foliate の枠の切り替え（純関数）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { isImageOnlySection, layoutChanges, IMAGE_SECTION_ATTRS, shouldToggleBar }
    from "../Sources/LibraryServer/Resources/web/epub-section.js";

/// querySelectorAll の件数だけを返す最小の document。
function fakeDoc(text, counts = {}) {
    return { body: { textContent: text, querySelectorAll: (sel) => ({ length: counts[sel] ?? 0 }) } };
}

test("画像 1 枚だけ（img）の章は画像の章", () => {
    assert.equal(isImageOnlySection(fakeDoc("\n  \t", { img: 1 })), true);
});

test("svg 1 つ（中に image）の章も画像の章", () => {
    assert.equal(isImageOnlySection(fakeDoc("", { svg: 1 })), true);
});

test("文字があれば画像の章ではない", () => {
    assert.equal(isImageOnlySection(fakeDoc("第一章", { img: 1 })), false);
});

test("画像が 2 つ以上なら画像の章ではない（枠を残す）", () => {
    assert.equal(isImageOnlySection(fakeDoc("", { img: 2 })), false);
    assert.equal(isImageOnlySection(fakeDoc("", { img: 1, svg: 1 })), false);
});

test("画像も文字も無い章・body の無い文書・null は画像の章ではない", () => {
    assert.equal(isImageOnlySection(fakeDoc("")), false);
    assert.equal(isImageOnlySection({}), false);
    assert.equal(isImageOnlySection(null), false);
});

test("layoutChanges: 文字 → 画像で 5 つの属性を当て、max-inline-size を最後にする", () => {
    const ops = layoutChanges(false, true);
    assert.deepEqual(Object.fromEntries(ops), IMAGE_SECTION_ATTRS);
    assert.equal(ops.at(-1)[0], "max-inline-size");
    assert.equal(IMAGE_SECTION_ATTRS.margin, "0px");
    assert.equal(IMAGE_SECTION_ATTRS.gap, "0%");
    assert.equal(IMAGE_SECTION_ATTRS["max-column-count"], "1");
});

test("layoutChanges: 画像 → 文字で全部外す（null＝既定値に戻す）", () => {
    const ops = layoutChanges(true, false);
    assert.deepEqual(ops.map(([n]) => n), Object.keys(IMAGE_SECTION_ATTRS));
    assert.ok(ops.every(([, v]) => v === null));
});

test("layoutChanges: 変化が無ければ何もしない（再描画を起こさない）", () => {
    assert.deepEqual(layoutChanges(true, true), []);
    assert.deepEqual(layoutChanges(false, false), []);
});

test("shouldToggleBar: 素のクリックでバーを出し入れする", () => {
    assert.equal(shouldToggleBar({ defaultPrevented: false, onLink: false, hasSelection: false }), true);
});

test("shouldToggleBar: リンク・文字選択中・処理済みのクリックでは出し入れしない", () => {
    assert.equal(shouldToggleBar({ defaultPrevented: false, onLink: true, hasSelection: false }), false);
    assert.equal(shouldToggleBar({ defaultPrevented: false, onLink: false, hasSelection: true }), false);
    assert.equal(shouldToggleBar({ defaultPrevented: true, onLink: false, hasSelection: false }), false);
});
