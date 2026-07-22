// SPDX-License-Identifier: MIT
import { test } from "node:test";
import assert from "node:assert/strict";
import { pagesForView, step } from "../Sources/LibraryServer/Resources/web/reader.js";

test("見開き ON では先頭ページを単独表示する（表紙相当）", () => {
    assert.deepEqual(pagesForView(0, true, 10, {}), [0]);
});

test("2 ページ目以降は従来どおり 2 枚ずつ組む", () => {
    assert.deepEqual(pagesForView(1, true, 10, {}), [1, 2]);
    assert.deepEqual(pagesForView(3, true, 10, {}), [3, 4]);
});

test("先頭に forcePair(0) が付いていればペアを組む", () => {
    assert.deepEqual(pagesForView(0, true, 10, { 0: 0 }), [0, 1]);
});

test("先頭が forceSolo(1) でも単独（冗長指定でも壊れない）", () => {
    assert.deepEqual(pagesForView(0, true, 10, { 0: 1 }), [0]);
});

test("見開き OFF は不変", () => {
    assert.deepEqual(pagesForView(0, false, 10, {}), [0]);
    assert.deepEqual(pagesForView(3, false, 10, {}), [3]);
});

test("前進: 0 -> 1 -> 3 -> 5", () => {
    assert.equal(step(0, 1, true, 10, {}), 1);
    assert.equal(step(1, 1, true, 10, {}), 3);
    assert.equal(step(3, 1, true, 10, {}), 5);
});

test("後退: 5 -> 3 -> 1 -> 0（前進と対称）", () => {
    assert.equal(step(5, -1, true, 10, {}), 3);
    assert.equal(step(3, -1, true, 10, {}), 1);
    assert.equal(step(1, -1, true, 10, {}), 0);
    assert.equal(step(0, -1, true, 10, {}), 0);
});

test("1 ページだけの本でも壊れない", () => {
    assert.deepEqual(pagesForView(0, true, 1, {}), [0]);
    assert.equal(step(0, 1, true, 1, {}), 0);
});
