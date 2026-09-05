// SPDX-License-Identifier: MIT
// StackNest Web — テキスト EPUB リーダー（foliate-js）。
// G48-3: 画像本 EPUB は manifest がページ経路（pageCount>0）を返すのでここには来ない。
// 位置は共有 locator（epub-locator.js）で /epub-progress へ書き戻す（Mac リモート閲覧と共通）。

import { fetchBookFileBlob, postEPUBProgress } from "./api.js";
import { toLocator, restoreTarget, clampScale } from "./epub-locator.js";

const SCALE_KEY = "stacknest.epubFontScale";
const readScale = () => clampScale(localStorage.getItem(SCALE_KEY));
const saveScale = (s) => localStorage.setItem(SCALE_KEY, String(s));

/// foliate の renderer（各セクションの document）に注入するスタイル。倍率と配色
/// （prefers-color-scheme のみに追従。手動トグルは無し — G48-3 controller ruling）。
function styles(scale) {
    return `
        html { font-size: ${Math.round(scale * 100)}% !important; }
        @media (prefers-color-scheme: dark) {
            html { color-scheme: dark; background: #1b1b1b !important; color: #e6e6e6 !important; }
            a { color: #8ab4f8; }
        }
    `;
}

function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/// テキスト EPUB を foliate-js で描画する。deps は renderReader と同じ形
/// （{ el, toast, appEl, cancelActiveTransition, ... }）。
/// backHash は reader.js 側で resolveBackHash(uuid, query) 済みの「戻る」先 hash
/// （resolveBackHash 自体は reader.js から export されているが、ここから import すると
/// reader.js ⇄ epub-reader.js の循環になるため引数で受け取る）。
///
/// 戻り値: teardown 関数（reader.js の activeReaderTeardown にそのまま登録できる）。
/// 呼び出し側は `activeReaderTeardown = await renderEPUBReader(...)` の形で使うこと。
///
/// レース対策: hashchange の監視は本文取得（/file）より前、DOM をマウントした直後に
/// 登録する。JS はここから最初の await まで同期実行されるため、ダウンロード中に
/// hash が変わっても onHashChange が確実に発火し teardown() が walk する
/// （root は既に appEl() 配下にあるので取りこぼしが無い）。以降の各 await の後でも
/// torn を確認し、既に teardown 済みなら以降の処理（view.open 等）を行わない。
export async function renderEPUBReader(uuid, bookId, query, deps, manifest, backHash) {
    const { el, toast, appEl, cancelActiveTransition } = deps;
    document.title = "StackNest";

    let scale = readScale();
    let torn = false;

    // DOM: 既存リーダーと同じ「戻る」＋左右タップ域＋倍率ボタン。
    const view = document.createElement("foliate-view");
    view.className = "epub-view";
    const backBtn = el("button", {
        class: "icon-btn", type: "button", "aria-label": "戻る",
        onClick: () => goBack(),
    }, "‹");
    const smallerBtn = el("button", {
        class: "icon-btn", type: "button", "aria-label": "文字を小さく",
        onClick: () => setScale(scale / 1.122),
    }, "A−");
    const biggerBtn = el("button", {
        class: "icon-btn", type: "button", "aria-label": "文字を大きく",
        onClick: () => setScale(scale * 1.122),
    }, "A+");
    const bar = el("div", { class: "epub-bar" }, [
        backBtn,
        el("span", { class: "epub-spacer" }),
        smallerBtn,
        biggerBtn,
    ]);
    const tapLeft = el("div", { class: "epub-tap epub-tap-left", onClick: () => view.goLeft() });
    const tapRight = el("div", { class: "epub-tap epub-tap-right", onClick: () => view.goRight() });
    const root = el("div", { class: "epub-reader" }, [bar, view, tapLeft, tapRight]);

    const applyStyles = () => view.renderer?.setStyles?.(styles(scale));
    const setScale = (s) => { scale = clampScale(s); saveScale(scale); applyStyles(); };

    // 位置の書き戻し: 1 秒デバウンス＋離脱（pagehide/teardown）で即時 flush。best-effort
    // （既存 postProgress 呼び出しと同じ扱い。相手が居なくてもリーダー体験は継続する）。
    let pending = null;
    let flushTimer = null;
    const flush = () => {
        if (!pending) return;
        const loc = pending;
        pending = null;
        clearTimeout(flushTimer);
        flushTimer = null;
        postEPUBProgress(uuid, bookId, loc).catch(() => {});
    };
    const schedule = (loc) => {
        pending = loc;
        clearTimeout(flushTimer);
        flushTimer = setTimeout(flush, 1000);
    };

    // キー操作。
    function onKey(e) {
        if (e.key === "ArrowLeft") { view.goLeft(); e.preventDefault(); }
        else if (e.key === "ArrowRight") { view.goRight(); e.preventDefault(); }
        else if (e.key === " " || e.key === "PageDown") { view.next(); e.preventDefault(); }
        else if (e.key === "PageUp") { view.prev(); e.preventDefault(); }
        else if (e.key === "Escape") { e.preventDefault(); goBack(); }
    }

    function onPageHide() { flush(); }

    // このリーダーの route から離れたかどうかは reader.js と同じ判定（#/lib/<uuid>/read/<bookId>...）。
    const readerHashPattern = new RegExp(
        `^#/lib/${escapeRegExp(encodeURIComponent(uuid))}/read/${escapeRegExp(String(bookId))}`
    );
    function onHashChange() {
        if (!readerHashPattern.test(location.hash)) teardown();
    }

    // teardown は冪等。listener の解除・flush・root 除去のすべてをここに集約する。
    // view.close()（foliate-js 側の後始末: renderer の破棄・zip アーカイブの解放）は
    // open() が未完了でも安全に呼べる（内部で optional chaining されている）ので、
    // ロード中の離脱でも確実に呼ぶ。
    function teardown() {
        if (torn) return;
        torn = true;
        flush();
        clearTimeout(flushTimer);
        window.removeEventListener("keydown", onKey);
        window.removeEventListener("pagehide", onPageHide);
        window.removeEventListener("hashchange", onHashChange);
        try { view.close?.(); } catch {}
        root.remove();
    }

    function goBack() {
        teardown();
        location.hash = backHash;
    }

    // マウント（既存リーダーと同じ手順: 進行中の空間遷移があれば先に確定させてから appEl() を差し替える）。
    cancelActiveTransition?.();
    const main = appEl();
    while (main.firstChild) main.removeChild(main.firstChild);
    main.append(root);

    // hashchange/pagehide/keydown はダウンロード開始前に登録する（レース対策。上のコメント参照）。
    window.addEventListener("keydown", onKey);
    window.addEventListener("pagehide", onPageHide);
    window.addEventListener("hashchange", onHashChange);

    // 本を取得して開く。
    try {
        await import("./vendor/foliate-js/view.js");
        if (torn) return teardown;
        const blob = await fetchBookFileBlob(uuid, bookId);
        if (torn) return teardown;
        const file = new File([blob], `${bookId}.epub`, { type: "application/epub+zip" });
        await view.open(file);
        if (torn) return teardown;
        applyStyles();
        // renderer の relocate は {index, fraction}（spine 内の進行率）。view はこの内部リスナーを
        // open() の中で自分の renderer に先に登録しているため、ここで addEventListener した時点で
        // 既に後着になり、view.lastLocation.cfi はこのハンドラが呼ばれる時点で更新済みになる。
        view.renderer.addEventListener("relocate", (e) => {
            if (torn) return;
            const { index, fraction } = e.detail;
            schedule(toLocator({ index, fraction, cfi: view.lastLocation?.cfi }));
        });
        const target = restoreTarget(manifest.epubLocator);
        if (torn) return teardown;
        if (typeof target === "string") await view.init({ lastLocation: target });
        else if (target) await view.renderer.goTo(target);
        else await view.init({ showTextStart: true });
    } catch (e) {
        if (!torn) toast("本を開けませんでした");
        console.error(e);
    }

    return teardown;
}
