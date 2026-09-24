// SPDX-License-Identifier: MIT
// StackNest Web — テキスト EPUB リーダー（foliate-js）。
// G48-3: 画像本 EPUB は manifest がページ経路（pageCount>0）を返すのでここには来ない。
// 位置は共有 locator（epub-locator.js）で /epub-progress へ書き戻す（Mac リモート閲覧と共通）。

import { fetchBookFileBlob, postEPUBProgress, UnauthorizedError, NetworkError } from "./api.js";
import { toLocator, restoreTarget, clampScale } from "./epub-locator.js";
import { isImageOnlySection, layoutChanges, shouldToggleBar, imageChainAncestors } from "./epub-section.js";

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
        /* G54-S3d/smoke-fix 修正: 画像 1 枚だけの章は ZIP ビューアと同じくレターボックス表示にする
           （画像を中央寄せし、上下（縦書きなら左右）は .epub-reader の背景色の帯）。html に
           付けた sn-image-only クラス（このファイルの load リスナーが付け外しする）が居るときだけ効く。
           flex は writing-mode に追従するので main/cross 軸を明示しなくても縦書き（vertical-rl）の
           本でも同じ書き方で中央寄せになる。
           smoke-fix round 2 (2026-09-24): 最初の修正は `body > *`（1 段だけ）を対象にしていたが、
           実機で `<section class="p-cover"><div class="main"><svg>...</svg></div></section>`
           のように 2 段（以上）包む本があり、伸びるのは section だけで中の div がまた
           shrink-to-fit に戻り、svg の width:100% が再び循環参照になって余白が戻った。
           決め打ちの深さをやめ、load リスナーが leaf（img/svg）から body までの**祖先すべて**に
           JS で `sn-image-chain` クラスを付け（epub-section.js の imageChainAncestors、
           book の CSS 側の詳細度に依存しない）、body と `.sn-image-chain` に**同一のルール**
           （100%×100%・flex column・stretch・center）を当てる。各段が「親から 100% の確定box を
           もらって同じ box を子に渡す」形になるので、何段包まれていても再帰的に効く（Playwright
           ヘッドレス計測: 2 段 section>div>svg・3 段包み・縦書きの 2 段包みで確認。書籍側 CSS が
           wrapper に margin/height:auto/display:inline-block を付けている想定も模擬して
           上書きできることを確認 — 詳細は smoke-fix-image-width-report.md の Fix round 2）。 */
        html.sn-image-only body,
        html.sn-image-only .sn-image-chain {
            box-sizing: border-box !important;
            width: 100% !important;
            height: 100% !important;
            margin: 0 !important;
            padding: 0 !important;
            border: 0 !important;
            float: none !important;
            display: flex !important;
            flex-direction: column !important;
            justify-content: center !important;
            align-items: stretch !important;
        }
        html.sn-image-only body img,
        html.sn-image-only body svg {
            max-width: 100% !important;
            max-height: 100% !important;
            object-fit: contain !important;
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
    // G54-S3d: バーは zip の .reader-chrome と同じく本文の上に重ね、画面中央のタップで出し入れする。
    // 中央には透明な操作域を置かない（本文のリンク・文字選択を塞がないため）。左右の操作域に当たらなかった
    // クリック（＝中央）を、foliate の要素（章の外の余白）と各章の文書（下の load の受け手）で受ける。
    const root = el("div", { class: "epub-reader" }, [view, tapLeft, tapRight, bar]);
    let barVisible = true;
    const toggleBar = () => {
        barVisible = !barVisible;
        bar.classList.toggle("hidden", !barVisible);
    };
    view.addEventListener("click", () => { if (!torn) toggleBar(); });

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
        // 最終レビュー I2: 終端を閉じる（read/1 が read/12 に前方一致しないように）
        `^#/lib/${escapeRegExp(encodeURIComponent(uuid))}/read/${escapeRegExp(String(bookId))}(?=[/?#]|$)`
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
        document.documentElement.classList.remove("sn-scroll-lock");
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
    // G54 web smoke: リーダー表示中は背後のドキュメントのスクロールを止める（style.css の
    // html.sn-scroll-lock 参照）。teardown() で必ず外す（全離脱経路が teardown() を通る）。
    document.documentElement.classList.add("sn-scroll-lock");

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
        // G54-S3d: 画像 1 枚だけの章では foliate の枠（余白・段組み）を外し、文字の章で戻す。
        // foliate は章を読み込むたびに load を出し、その直後（同期）に枠の値を読んで描画する
        // （paginator.js: iframe の load → afterLoad → load イベント → #beforeRender）ので、ここで当てた値はその章に効く。
        // 最初の章もここを通る（open の後・init の前に登録している）。
        let imageSection = false;
        view.addEventListener("load", (e) => {
            if (torn) return;
            const doc = e.detail?.doc;
            const imageOnly = isImageOnlySection(doc);
            // G54-S3d 修正: styles() の `.sn-image-only` はこのクラスがある間だけ効く。
            // setStyles() は全章共通の <style> を差し込むだけなので、章ごとの出し分けは
            // この documentElement のクラスで行う（margin 等の renderer 属性と同じ理由で
            // load の同期処理内で当てる＝この章の描画に間に合う）。
            doc?.documentElement?.classList.toggle("sn-image-only", imageOnly);
            // smoke-fix round 2: 本の XHTML が何段包んでいても styles() の `.sn-image-chain`
            // ルールが効くよう、leaf（img/svg）から body までの祖先すべてに印を付ける
            // （section ごとに doc は毎回新規なので、外す処理は不要 — 前章の印が残ることはない）。
            if (imageOnly) {
                const leaf = doc.body.querySelector("img, svg");
                for (const el of imageChainAncestors(leaf, doc.body)) el.classList.add("sn-image-chain");
            }
            for (const [name, value] of layoutChanges(imageSection, imageOnly)) {
                if (value === null) view.renderer.removeAttribute(name);
                else view.renderer.setAttribute(name, value);
            }
            imageSection = imageOnly;
        });
        // G54-S3d: 章の文書の中のクリック（iframe の中なので上の view の click には届かない）。
        view.addEventListener("load", (e) => {
            if (torn) return;
            const doc = e.detail?.doc;
            doc?.addEventListener("click", (ev) => {
                if (torn) return;
                const onLink = Boolean(ev.target?.closest?.("a[href]"));
                const hasSelection = String(doc.getSelection?.() ?? "") !== "";
                if (shouldToggleBar({ defaultPrevented: ev.defaultPrevented, onLink, hasSelection })) toggleBar();
            });
        });
        // renderer の relocate は {index, fraction}（spine 内の進行率）。view はこの内部リスナーを
        // open() の中で自分の renderer に先に登録しているため、ここで addEventListener した時点で
        // 既に後着になり、view.lastLocation.cfi はこのハンドラが呼ばれる時点で更新済みになる。
        view.renderer.addEventListener("relocate", (e) => {
            if (torn) return;
            const { index, fraction } = e.detail;
            schedule(toLocator({ index, fraction, cfi: view.lastLocation?.cfi }));
        });
        // G54-S3d: 本の詳細シートで「最初から」を選んだ（restart=1）。本の先頭から開き、その位置を保存する
        // （次に開いたときにまた訊かれないように。Mac の「最初から」と同じ考え方）。先頭の保存を先に送り、
        // 移動後の relocate（cfi 付きの同じ位置）が 1 秒のデバウンスの後に上書きする。
        if (query?.restart === "1") {
            postEPUBProgress(uuid, bookId, toLocator({ index: 0, fraction: 0 })).catch(() => {});
            await view.renderer.goTo({ index: 0, anchor: 0 });
            view.history?.pushState?.(0);
            return teardown;
        }
        const target = restoreTarget(manifest.epubLocator);
        if (torn) return teardown;
        // 最終レビュー I1: cfi が解決できなければ spine+progress へ、index が範囲外なら先頭へ落とす
        // （renderer.goTo は範囲外を黙って無視し、init は解決失敗で先頭へ行って位置を上書きしてしまう）。
        const sectionCount = view.book?.sections?.length ?? 0;
        const loc = manifest.epubLocator;
        const fallback = loc && sectionCount > 0
            ? { index: Math.min(Math.max(0, Math.floor(Number(loc.spine) || 0)), sectionCount - 1), anchor: Math.min(1, Math.max(0, Number(loc.progress) || 0)) }
            : null;
        // resolveNavigation は「解決できた」だけを返し、spine index が範囲外（存在しない章の cfi）でも
        // {index} を返してしまう。範囲内のときだけ cfi を信じる（自走 smoke で白画面を再現して確認）。
        const resolved = typeof target === "string" ? view.resolveNavigation(target) : null;
        const cfiUsable = resolved && Number.isInteger(resolved.index) && resolved.index >= 0 && resolved.index < sectionCount;
        if (cfiUsable) await view.init({ lastLocation: target });
        else if (fallback) { await view.renderer.goTo(fallback); view.history?.pushState?.(fallback.index); }   // history には resolveNavigation が解ける形（index）で積む
        else await view.init({ showTextStart: true });
    } catch (e) {
        // T4 レビュー Important #1: 401 は api.js が #/pair へ遷移済み（reader.js と同じ扱い）。誤った toast を出さない。
        if (e instanceof UnauthorizedError) return teardown;
        if (!torn) toast(e instanceof NetworkError ? "サーバに接続できません" : "本を開けませんでした");
        console.error(e);
    }

    return teardown;
}
