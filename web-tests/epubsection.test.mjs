// SPDX-License-Identifier: MIT
// G54-S3d: テキスト EPUB の「画像 1 枚だけの章」の判定と、foliate の枠の切り替え（純関数）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { isImageOnlySection, layoutChanges, IMAGE_SECTION_ATTRS, shouldToggleBar, imageChainAncestors, svgAspectRatioTargets }
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

/// parentElement だけを持つ最小要素。fakeChain("leaf","div","section","body") のように
/// 内側から外側の順で並べて渡すと、その順で parentElement を繋いで最後の要素を body として返す。
function fakeChain(...names) {
    const els = names.map((name) => ({ name, parentElement: null }));
    for (let i = 0; i < els.length - 1; i++) els[i].parentElement = els[i + 1];
    return els;
}

test("imageChainAncestors: leaf が body の直下なら祖先は無し", () => {
    const [leaf, body] = fakeChain("leaf", "body");
    assert.deepEqual(imageChainAncestors(leaf, body), []);
});

test("imageChainAncestors: 1 段包み（<div><svg></div>）は div だけ", () => {
    const [leaf, div, body] = fakeChain("leaf", "div", "body");
    assert.deepEqual(imageChainAncestors(leaf, body), [div]);
});

test("imageChainAncestors: 2 段包み（<section><div><svg></div></section>）は内側→外側の順", () => {
    const [leaf, div, section, body] = fakeChain("leaf", "div", "section", "body");
    assert.deepEqual(imageChainAncestors(leaf, body), [div, section]);
});

test("imageChainAncestors: 3 段包みでも同じ形で全段を拾う", () => {
    const [leaf, a, b, c, body] = fakeChain("leaf", "a", "b", "c", "body");
    assert.deepEqual(imageChainAncestors(leaf, body), [a, b, c]);
});

test("imageChainAncestors: leaf/body が無ければ空（例外を投げない）", () => {
    const [leaf, body] = fakeChain("leaf", "body");
    assert.deepEqual(imageChainAncestors(null, body), []);
    assert.deepEqual(imageChainAncestors(leaf, null), []);
    assert.deepEqual(imageChainAncestors(null, null), []);
});

test("imageChainAncestors: body に辿り着かない（親が途中で尽きる）場合は打ち切る", () => {
    const leaf = { parentElement: { parentElement: null } };
    const unrelatedBody = { name: "body" };
    assert.deepEqual(imageChainAncestors(leaf, unrelatedBody), [leaf.parentElement]);
});

/// image 要素の querySelectorAll("image") だけに応答する最小の svg 要素。
function fakeSvg(images = []) {
    return { localName: "svg", querySelectorAll: (sel) => (sel === "image" ? images : []) };
}

test("svgAspectRatioTargets: image を含まない svg は svg 自身のみ", () => {
    const svg = fakeSvg([]);
    assert.deepEqual(svgAspectRatioTargets(svg), [svg]);
});

test("svgAspectRatioTargets: svg の中の image も含める（Calibre の <svg><image></svg> 形）", () => {
    const image = { name: "image" };
    const svg = fakeSvg([image]);
    assert.deepEqual(svgAspectRatioTargets(svg), [svg, image]);
});

test("svgAspectRatioTargets: 複数 image があれば全部含める", () => {
    const image1 = { name: "image1" };
    const image2 = { name: "image2" };
    const svg = fakeSvg([image1, image2]);
    assert.deepEqual(svgAspectRatioTargets(svg), [svg, image1, image2]);
});

test("svgAspectRatioTargets: leaf が img（svg でない）なら空", () => {
    assert.deepEqual(svgAspectRatioTargets({ localName: "img" }), []);
});

test("svgAspectRatioTargets: leaf が無ければ空（例外を投げない）", () => {
    assert.deepEqual(svgAspectRatioTargets(null), []);
    assert.deepEqual(svgAspectRatioTargets(undefined), []);
});
