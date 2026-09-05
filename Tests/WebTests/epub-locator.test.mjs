import { test } from "node:test";
import assert from "node:assert/strict";
import { toLocator, restoreTarget, clampScale } from "../../Sources/LibraryServer/Resources/web/epub-locator.js";

test("toLocator: index/fraction/cfi を写す", () => {
    assert.deepEqual(toLocator({ index: 3, fraction: 0.25, cfi: "epubcfi(/6/8!/4/2)" }),
        { spine: 3, progress: 0.25, cfi: "epubcfi(/6/8!/4/2)", engine: "foliate" });
});
test("toLocator: 範囲外は丸め、cfi 無しは null", () => {
    assert.deepEqual(toLocator({ index: -1, fraction: 1.7 }), { spine: 0, progress: 1, cfi: null, engine: "foliate" });
    assert.deepEqual(toLocator({ index: "x", fraction: NaN }), { spine: 0, progress: 0, cfi: null, engine: "foliate" });
});
test("restoreTarget: foliate の cfi はそのまま", () => {
    assert.equal(restoreTarget({ spine: 1, progress: 0.5, cfi: "epubcfi(/6/4)", engine: "foliate" }), "epubcfi(/6/4)");
});
test("restoreTarget: 他エンジンの cfi は捨てて spine+progress", () => {
    assert.deepEqual(restoreTarget({ spine: 4, progress: 0.5, cfi: "washi-opaque", engine: "washi" }), { index: 4, anchor: 0.5 });
    assert.deepEqual(restoreTarget({ spine: 4, progress: 0.5 }), { index: 4, anchor: 0.5 });
});
test("restoreTarget: 無ければ null", () => {
    assert.equal(restoreTarget(null), null);
    assert.equal(restoreTarget(undefined), null);
});
test("clampScale: 未保存（null/undefined/空）は 1.0（自走 smoke で見つかった退行）", () => {
    assert.equal(clampScale(null), 1); assert.equal(clampScale(undefined), 1); assert.equal(clampScale(""), 1);
    assert.deepEqual(toLocator({ index: null, fraction: undefined }), { spine: 0, progress: 0, cfi: null, engine: "foliate" });
});
test("clampScale", () => {
    assert.equal(clampScale(0.1), 0.5); assert.equal(clampScale(9), 3); assert.equal(clampScale("a"), 1); assert.equal(clampScale(1.25), 1.25);
});
