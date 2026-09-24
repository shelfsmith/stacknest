// SPDX-License-Identifier: MIT
// G54-S3d smoke: Web の全スクリプトが構文として読めることを確かめる。
// epub-reader.js はブラウザでしか import されず、他のテストでは読み込まれないため、
// CSS を書いたテンプレートリテラル内のバッククォートで文字列が途中で閉じる構文エラーが
// テストを素通りし、実機で全テキスト EPUB が開けなくなった（2026-09-24）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const webDir = join(dirname(fileURLToPath(import.meta.url)), "..", "Sources", "LibraryServer", "Resources", "web");
const files = readdirSync(webDir).filter((f) => f.endsWith(".js"));

test("Web のスクリプトが 1 つ以上ある", () => {
    assert.ok(files.length > 0);
});

for (const f of files) {
    test(`${f} が構文として読める`, () => {
        const src = readFileSync(join(webDir, f), "utf8");
        const r = spawnSync(process.execPath, ["--check", "--input-type=module"], { input: src, encoding: "utf8" });
        assert.equal(r.status, 0, `${f}: ${r.stderr}`);
    });
}
