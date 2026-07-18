// SPDX-License-Identifier: MIT
// StackNest Web — リーダー画面（タップ/スワイプ/キーボードナビ、見開き、progress 書き戻し）。
// Task R4。

import { fetchManifest, fetchPageBlob, postProgress, postDirection, postPageLayout, fetchAdjacent, UnauthorizedError, NetworkError } from "./api.js";
import { deleteBook, clearAll, purgeExpired } from "./idb.js";
import { PrefetchEngine } from "./prefetch.js";
import { readerPrefs, setReaderPref } from "./prefs.js";

// 同時に存在するリーダーは 1 つ。再マウント前に前インスタンスを確実に teardown する。
let activeReaderTeardown = null;

// ---- 純関数（export） ---------------------------------------------------------

/// 見開き or 単頁表示において、cur 位置で表示する apiIndex の配列を返す。
/// 単頁: [apiIndex]。見開き: 次頁が存在すれば [apiIndex, apiIndex+1]、なければ [apiIndex]。
///
/// G17 T6b: overrides は { [apiIndex]: 0|1 }（0=forcePair/1=forceSolo、サーバの
/// book_page_layout と同じ raw mode）。apiIndex 自身が forceSolo なら単独表示、次頁が
/// forceSolo ならそのページを巻き込まず apiIndex 単独で表示する（forceSolo ページを常に
/// 単独の見開きにする＝そのページの手前で組み分けが切れる）。overrides 未指定時は
/// 従来どおり（override 無しのケースと完全に同じ結果）。
export function pagesForView(apiIndex, spread, pageCount, overrides = {}) {
    if (!spread) return [apiIndex];
    if (overrides[apiIndex] === 1) return [apiIndex];
    const second = apiIndex + 1;
    if (second >= pageCount) return [apiIndex];
    if (overrides[second] === 1) return [apiIndex];
    return [apiIndex, second];
}

/// ナビゲーション移動後の apiIndex を返す。
/// dir: +1(次) / -1(前)。見開き時は現在(前)の view の枚数分だけ移動する
/// （override が無ければ従来どおり常に 2、override があれば pagesForView と整合する
/// 可変幅の移動になる — G17 T6b）。
export function step(apiIndex, dir, spread, pageCount, overrides = {}) {
    if (!spread) return Math.max(0, Math.min(pageCount - 1, apiIndex + dir));
    if (dir > 0) {
        const size = pagesForView(apiIndex, spread, pageCount, overrides).length;
        return Math.max(0, Math.min(pageCount - 1, apiIndex + size * dir));
    }
    // 後退: 直前の view のアンカーを逆算する。pagesForView(prevPrev) が
    // [prevPrev, prev] を返す条件（どちらも forceSolo でない）と同じ判定を使い、
    // 前進計算と対称になるようにする（apiIndex が既に有効なアンカーである前提）。
    const prev = apiIndex - 1;
    if (prev < 0) return 0;
    const prevPrev = prev - 1;
    const pairsWithPrevPrev = prevPrev >= 0 && overrides[prevPrev] !== 1 && overrides[prev] !== 1;
    const anchor = pairsWithPrevPrev ? prevPrev : prev;
    return Math.max(0, Math.min(pageCount - 1, anchor));
}

// ---- メイン export -----------------------------------------------------------

/// リーダー画面を描画する。
/// deps: { el, render, toast, appEl, onLibraryUnshared }
/// query: parseRoute() の query（p=uiPage を含む）
export async function renderReader(uuid, bookId, query, deps) {
    const { el, toast, appEl, onLibraryUnshared } = deps;
    const maxw = 1600;
    const book = `${uuid}|${bookId}`;

    // 「戻る」先 hash。books.js openAt() が付与した from=（開いた時点の絞り込み一覧 hash）を
    // 優先し、直リンク/不正値のときのみ従来の #/lib/<uuid> にフォールバックする（G17 T2）。
    const backHash = resolveBackHash(uuid, query);

    // 前インスタンスが残っていれば掃除（多重マウント防止）
    if (activeReaderTeardown) { try { activeReaderTeardown(); } catch {} activeReaderTeardown = null; }

    // 1. manifest 取得
    let manifest;
    try {
        manifest = await fetchManifest(uuid, bookId);
    } catch (e) {
        if (e instanceof UnauthorizedError) return; // api.js が #/pair へ遷移済み
        if (e instanceof NetworkError) {
            toast("サーバに接続できません");
            location.hash = backHash;
            return;
        }
        if (e && e.status === 404) {
            toast("配信が停止されました");
            typeof onLibraryUnshared === "function" && onLibraryUnshared();
            return;
        }
        if (e && e.status === 403) {
            toast("このライブラリはロックされています");
            location.hash = "#/libraries";
            return;
        }
        toast(e.message || "読み込みに失敗しました");
        location.hash = backHash;
        return;
    }

    const { pageCount, format } = manifest;
    let direction = manifest.direction || "ltr";   // manifest は実効方向（本 override ?? アプリ既定）

    // G17 T6b: ページ単位の単頁/見開き override（{ [apiIndex]: 0|1 }）。manifest.pageOverrides は
    // { "<page>": mode } の文字列キー object なので数値キーへ正規化して読み込む
    // （JS のプロパティアクセスは overrides[3] でも overrides["3"] でも同じキーに解決されるため、
    // 以降は数値のまま扱ってよい）。
    const overrides = {};
    if (manifest.pageOverrides) {
        for (const [k, v] of Object.entries(manifest.pageOverrides)) overrides[Number(k)] = v;
    }

    // 2. resume: p は uiPage（1始まり）→ apiIndex（0始まり）に変換
    const startUi = Math.max(1, Math.min(pageCount, Number(query.p) || 1));
    let cur = startUi - 1; // apiIndex

    // 3. PrefetchEngine 構築
    purgeExpired();   // 7日以上アクセスの無いページキャッシュを掃除（await 不要・best-effort）
    const prefs = readerPrefs();
    const engine = new PrefetchEngine({
        uuid, bookId, pageCount, maxw, book,
        tier3Enabled: prefs.tier3Enabled,
        cacheLimitBytes: prefs.cacheLimitBytes,
        fetchPageBlob,
    });

    // 4. 見開き状態（保存済み値優先。未設定時はビューポート幅で決める: ≥768px → ON、iPhone → OFF）
    const savedSpread = readerPrefs().spread;   // undefined = 未設定（幅で決める）
    let spread = (typeof savedSpread === "boolean")
        ? savedSpread
        : window.matchMedia("(min-width: 768px)").matches;   // PC/iPad 既定 ON・iPhone OFF

    // 5. エフェメラル objectURL（表示中ビュー分のみ保持）
    // LRU は廃止。IndexedDB が本来のキャッシュ。
    let displayedURLs = [];   // 現在 DOM にある objectURL（次の差替で revoke）

    function revokeDisplayed() {
        for (const u of displayedURLs) URL.revokeObjectURL(u);
        displayedURLs = [];
    }

    // デコード済み <img> を作る。失敗時はキャッシュを捨てて 1 回再取得。
    // 404/403/AbortError 等は requestPage が throw → 呼び出し側(show)で処理。
    async function makeDecodedImg(apiIndex) {
        let lastErr;
        for (let attempt = 0; attempt < 2; attempt++) {
            const blob = await engine.requestPage(apiIndex, attempt > 0); // attempt>0 で bypass 再取得
            const url = URL.createObjectURL(blob);
            const img = el("img", { class: "reader-page", alt: `ページ ${apiIndex + 1}`, draggable: "false" });
            img.src = url;
            try {
                if (img.decode) { await img.decode(); }   // デコード可能になるまで待つ（壊れていれば reject）
                return { img, url };
            } catch (e) {
                URL.revokeObjectURL(url);
                lastErr = e;
                // 次ループで bypass 再取得
            }
        }
        throw lastErr || new Error("decode failed");
    }

    // 6. progress debounce
    let progressTimer = null;

    function scheduleProgress(apiIndex) {
        clearTimeout(progressTimer);
        progressTimer = setTimeout(() => flushProgress(apiIndex), 800);
    }

    async function flushProgress(apiIndex) {
        clearTimeout(progressTimer);
        try {
            await postProgress(uuid, bookId, apiIndex);
        } catch (e) {
            if (e && e.status === 404) {
                typeof onLibraryUnshared === "function" && onLibraryUnshared();
            }
            // その他エラーは握り潰す（progress は best-effort）
        }
    }

    // 7. DOM 構築
    const stageEl = el("div", { class: "reader-stage" });
    const loadingEl = el("div", { class: "reader-loading hidden" }, ["読み込み中…"]);

    const backBtn = el("button", {
        class: "reader-back", type: "button", text: "‹",
        "aria-label": "戻る",
        onClick: () => goBack(),
    });
    const titleSpan = el("span", { class: "reader-title" });
    const gearBtn = el("button", {
        class: "reader-gear", type: "button", text: "⚙",
        "aria-label": "設定",
        onClick: () => openReaderSettings(),
    });
    const topChrome = el("div", { class: "reader-chrome top" }, [backBtn, titleSpan, gearBtn]);

    const spreadToggleBtn = el("button", {
        class: "reader-spread-toggle", type: "button",
        text: spread ? "見開き ON" : "見開き OFF",
        "aria-label": spread ? "見開きを解除" : "見開きモードにする",
        onClick: () => {
            spread = !spread;
            setReaderPref("spread", spread);   // 手動選択を localStorage に永続化
            spreadToggleBtn.textContent = spread ? "見開き ON" : "見開き OFF";
            spreadToggleBtn.setAttribute("aria-label", spread ? "見開きを解除" : "見開きモードにする");
            stepOneBtn.hidden = !spread;
            show(cur);
        },
    });

    // G17 T6b: cur（を含む view）が見開きペア表示かどうか。ov を省略すると現在の overrides を見る
    // （togglePageLayout が「override を外したら既定はどうなるか」を仮判定するのに ov を差し替えて使う）。
    function pageLayoutIsPaired(apiIndex, ov = overrides) {
        return pagesForView(apiIndex, true, pageCount, ov).length === 2;
    }

    // stepOneBtn のラベル/aria を cur の実効表示（override 込み）に同期する。
    function updatePageLayoutLabel() {
        const paired = pageLayoutIsPaired(cur);
        stepOneBtn.textContent = paired ? "単頁化" : "見開き化";
        stepOneBtn.setAttribute("aria-label", paired ? "このページを単独表示にする" : "このページを見開きにする");
    }

    // 表示中ページ(cur)の単頁/見開きを反転し、ローカル反映＋サーバへ永続化する（G17 T6b）。
    // ペア表示中なら強制単独(1)、単独表示中なら override を外して既定に戻す。既定でも
    // 単独のまま（終端 or 次頁が forceSolo）なら強制ペア(0)を試す。それも不可（最終ページ）なら
    // トーストのみで何もしない。
    async function togglePageLayout() {
        const target = cur;
        const pairedNow = pageLayoutIsPaired(target);
        let nextMode;
        if (pairedNow) {
            nextMode = 1;
        } else {
            const withoutOverride = { ...overrides };
            delete withoutOverride[target];
            if (pageLayoutIsPaired(target, withoutOverride)) {
                nextMode = null;   // 自分の forceSolo を外せば見開きに戻る
            } else {
                // 単頁なのは自分の override 以外の理由（次頁が単頁指定 / 最終ページ）。
                // forcePair(mode 0) は pagesForView が参照せず無効なので、正直に理由を示して中断する
                // （無効な書き込みも行わない）。
                toast("次のページが単頁指定、または最終ページのため見開きにできません");
                return;
            }
        }
        if (nextMode === null) delete overrides[target];
        else overrides[target] = nextMode;
        updatePageLayoutLabel();
        show(target);
        try {
            await postPageLayout(uuid, bookId, target, nextMode);
        } catch (e) {
            toast("ページ表示の保存に失敗しました");
        }
    }

    const stepOneBtn = el("button", {
        class: "reader-step-one", type: "button",
        text: pageLayoutIsPaired(cur) ? "単頁化" : "見開き化",
        "aria-label": pageLayoutIsPaired(cur) ? "このページを単独表示にする" : "このページを見開きにする",
        onClick: () => { togglePageLayout(); },
    });
    stepOneBtn.hidden = !spread;  // 初期は見開き OFF なので非表示
    const sliderEl = el("input", {
        class: "reader-slider",
        type: "range",
        min: "1",
        max: String(pageCount),
        value: String(cur + 1),
    });
    const counterEl = el("span", { class: "reader-counter", text: `${cur + 1} / ${pageCount}` });
    const bottomChrome = el("div", { class: "reader-chrome bottom" }, [
        spreadToggleBtn, stepOneBtn, sliderEl, counterEl,
    ]);

    // タップゾーン（透明操作領域）
    const tapLeft = el("div", { class: "tapzone left", onClick: () => go(physicalToDir("left", direction)) });
    const tapCenter = el("div", { class: "tapzone center", onClick: () => toggleChrome() });
    const tapRight = el("div", { class: "tapzone right", onClick: () => go(physicalToDir("right", direction)) });

    // タップゾーンと読み込みインジケータを stage に追加
    stageEl.append(tapLeft, tapCenter, tapRight, loadingEl);

    const readerEl = el("div", { class: "reader" }, [stageEl, topChrome, bottomChrome]);

    // appEl に直接 append（render() は使わない）
    // #app の旧画面 DOM をクリアしてからマウント（toast-host は #app 外なので消えない）
    const main = appEl();
    while (main.firstChild) main.removeChild(main.firstChild);
    main.append(readerEl);

    // 8. chrome トグル
    let chromeVisible = true;
    function toggleChrome() {
        chromeVisible = !chromeVisible;
        if (chromeVisible) {
            topChrome.classList.remove("hidden");
            bottomChrome.classList.remove("hidden");
        } else {
            topChrome.classList.add("hidden");
            bottomChrome.classList.add("hidden");
        }
    }

    // 9. 物理方向 → 送り方向の写像
    function physicalToDir(physical, dir) {
        const rtl = dir === "rtl";
        if (physical === "right") return rtl ? -1 : +1;
        return rtl ? +1 : -1;
    }

    // 10. ナビゲーション
    function go(dir) {
        const next = step(cur, dir, spread, pageCount, overrides);
        // 4.2c-11: 最終ページで次方向(dir>0)に進めない＝巻末。3択ダイアログを出す。
        if (next === cur && dir > 0) {
            showEndOfBookDialog();
            return;
        }
        show(next);
    }

    // 11. 描画トークン（非同期描画の連打ガード）
    let renderToken = 0;

    async function show(apiIndex) {
        const my = ++renderToken;
        cur = Math.max(0, Math.min(pageCount - 1, apiIndex));

        // UI 即時更新（スライダー・カウンタ）
        const uiPage = cur + 1;
        sliderEl.value = String(uiPage);
        sliderEl.style.direction = (direction === "rtl") ? "rtl" : "ltr";
        counterEl.textContent = `${uiPage} / ${pageCount}`;
        titleSpan.textContent = `ページ ${uiPage} / ${pageCount}`;
        updatePageLayoutLabel();   // G17 T6b: トグルボタンの表示を cur の実効表示に同期

        // 描画する apiIndex 配列
        const indices = pagesForView(cur, spread, pageCount, overrides);

        // 読み込み中インジケータを表示
        if (my === renderToken) loadingEl.classList.remove("hidden");

        // デコード済み <img> を取得（失敗時は bypass 再取得を含む）
        let made;
        try {
            made = await Promise.all(indices.map((i) => makeDecodedImg(i)));
        } catch (e) {
            if (my === renderToken) loadingEl.classList.add("hidden");
            if (my !== renderToken) return; // 古い描画は捨てる
            if (e && (e.status === 404 || e.status === 403)) {
                toast("配信が停止されました");
                typeof onLibraryUnshared === "function" && onLibraryUnshared();
            } else if (e && e.name === "AbortError") {
                return; // 中断は正常系
            } else {
                toast("ページを読み込めませんでした");
                location.hash = backHash;
                teardown();
            }
            return;
        }

        // 古い描画になっていたら作った URL を破棄
        if (my !== renderToken) { for (const m of made) URL.revokeObjectURL(m.url); return; }

        // 読み込み完了 → インジケータを隠す
        loadingEl.classList.add("hidden");

        // stage の既存コンテンツを除去して再構築（タップゾーン・loading は keep）
        const toRemove = [];
        for (const child of stageEl.children) {
            const cls = child.className || "";
            if (!cls.includes("tapzone") && !cls.includes("reader-loading")) toRemove.push(child);
        }
        for (const n of toRemove) stageEl.removeChild(n);

        // 前ビューの URL を revoke し、今回分を保持
        revokeDisplayed();
        displayedURLs = made.map((m) => m.url);
        const imgs = made.map((m) => m.img);

        if (spread && imgs.length === 2) {
            // 見開き: rtl は右に小さい apiIndex（右綴じ）
            const spreadWrap = el("div", { class: "reader-spread" });
            if (direction === "rtl") {
                // 右に小さい apiIndex = imgs[0] が右、imgs[1] が左
                spreadWrap.append(imgs[1], imgs[0]);
            } else {
                spreadWrap.append(imgs[0], imgs[1]);
            }
            stageEl.insertBefore(spreadWrap, tapLeft);
        } else {
            stageEl.insertBefore(imgs[0], tapLeft);
        }

        // 先読みエンジンに現在ページを通知
        engine.setCurrentPage(cur);

        // progress を debounce 送信
        scheduleProgress(cur);
    }

    // 12. スライダー操作
    sliderEl.addEventListener("input", () => {
        show(Number(sliderEl.value) - 1);
    });

    // 13. スワイプ（タッチ）
    let touchStartX = null;
    let touchStartY = null;
    stageEl.addEventListener("touchstart", (e) => {
        if (e.touches.length === 1) {
            touchStartX = e.touches[0].clientX;
            touchStartY = e.touches[0].clientY;
        }
    }, { passive: true });
    stageEl.addEventListener("touchend", (e) => {
        if (touchStartX === null) return;
        const dx = e.changedTouches[0].clientX - touchStartX;
        const dy = e.changedTouches[0].clientY - touchStartY;
        touchStartX = null;
        touchStartY = null;
        // 縦方向が支配的なら無視
        if (Math.abs(dy) > Math.abs(dx)) return;
        if (Math.abs(dx) < 40) return;
        // 左スワイプ（指が左へ）→ physicalToDir("right", direction)
        // 右スワイプ（指が右へ）→ physicalToDir("left", direction)
        if (dx < 0) {
            go(physicalToDir("right", direction));
        } else {
            go(physicalToDir("left", direction));
        }
    }, { passive: true });

    // 14. キーボードナビゲーション（document レベル）
    function onKeyDown(e) {
        switch (e.key) {
            case "ArrowRight":
                e.preventDefault();
                go(physicalToDir("right", direction));
                break;
            case "ArrowLeft":
                e.preventDefault();
                go(physicalToDir("left", direction));
                break;
            case " ":
                if (e.shiftKey) {
                    e.preventDefault();
                    go(-1);
                } else {
                    e.preventDefault();
                    go(+1);
                }
                break;
            case "PageDown":
                e.preventDefault();
                go(+1);
                break;
            case "PageUp":
                e.preventDefault();
                go(-1);
                break;
            case "Home":
                e.preventDefault();
                show(0);
                break;
            case "End":
                e.preventDefault();
                show(pageCount - 1);
                break;
            case "Escape":
                e.preventDefault();
                goBack();
                break;
            default:
                break;
        }
    }
    document.addEventListener("keydown", onKeyDown);

    // 15. visibilitychange / pagehide で progress flush
    function onVisibilityChange() {
        if (document.hidden) flushProgress(cur);
    }
    function onPageHide() {
        flushProgress(cur);
    }
    document.addEventListener("visibilitychange", onVisibilityChange);
    window.addEventListener("pagehide", onPageHide);

    // 16. teardown（冪等。torn ガードで本体は 1 回だけ実行）
    let torn = false;
    function teardown() {
        if (torn) return;
        torn = true;
        engine.stop();
        revokeDisplayed();
        document.removeEventListener("keydown", onKeyDown);
        document.removeEventListener("visibilitychange", onVisibilityChange);
        window.removeEventListener("pagehide", onPageHide);
        window.removeEventListener("hashchange", onHashChange);
        flushProgress(cur);          // 単一の flush ポイント（I2）
        if (prefs.clearCacheOnExit) {
            deleteBook(book).catch(() => {});
        }
        readerEl.remove();
        if (activeReaderTeardown === teardown) activeReaderTeardown = null;
    }

    // 17. hashchange 監視（リーダー離脱検出）
    const readerHashPattern = new RegExp(
        `^#/lib/${escapeRegExp(encodeURIComponent(uuid))}/read/${escapeRegExp(String(bookId))}`
    );
    function onHashChange() {
        if (!readerHashPattern.test(location.hash)) {
            teardown();
        }
    }
    window.addEventListener("hashchange", onHashChange);
    // このインスタンスを current として登録（次の renderReader 冒頭で旧インスタンスを掃除）
    activeReaderTeardown = teardown;

    // 18. 戻る導線（flush は teardown 内の 1 回に集約、goBack での二重送信を排除）
    // ヘッダ戻る/Esc/巻末「本を閉じる」はすべてこの goBack() を通るため、
    // backHash（from= があればその一覧 hash、なければ #/lib/<uuid>）が一貫して使われる（G17 T2）。
    function goBack() {
        teardown();   // teardown 内で flushProgress(cur) を実行
        location.hash = backHash;
    }

    // 4.2c-11: 巻末（最終ページで次送り）の3択ダイアログ。次の巻へ / 先頭へ / 本を閉じる。
    function showEndOfBookDialog() {
        // 多重表示ガード（タップ/キー連打で重ならないように）
        if (readerEl.querySelector(".reader-dialog-overlay")) return;
        const overlay = el("div", { class: "reader-dialog-overlay" });
        const panel = el("div", { class: "reader-dialog" });
        panel.append(el("p", { class: "reader-dialog-title", text: "巻末です" }));
        const close = () => overlay.remove();
        const nextBtn = el("button", { class: "reader-dialog-btn", type: "button", text: "次の巻へ" });
        nextBtn.addEventListener("click", async () => {
            close();
            let book = null;
            try { book = await fetchAdjacent(uuid, bookId, "next"); }
            catch { toast("次の巻を取得できませんでした"); return; }
            if (!book) { toast("これが最後の巻です"); return; }
            openVolume(book);
        });
        const headBtn = el("button", { class: "reader-dialog-btn", type: "button", text: "先頭へ" });
        headBtn.addEventListener("click", () => { close(); show(0); });
        const closeBtn = el("button", { class: "reader-dialog-btn", type: "button", text: "本を閉じる" });
        closeBtn.addEventListener("click", () => { close(); goBack(); });
        panel.append(nextBtn, headBtn, closeBtn);
        overlay.append(panel);
        overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
        readerEl.append(overlay);
    }

    // 4.2c-11: 次巻を開く。読みかけ(lastPage>0)なら「続き/最初」を選ばせる。
    // lastPage は API index(0始まり)なので、続きの UI ページは lastPage+1。最初は 1。
    function openVolume(book) {
        const last = book.lastPage ?? 0;
        const gotoVolume = (p) => {
            teardown();
            // 元の一覧 hash（backHash）を次巻の reader にも引き継ぐ。多巻読みでも
            // 最終的な「戻る」は最初に開いたときの絞り込み一覧へ戻る（G17 T2）。
            location.hash = `#/lib/${encodeURIComponent(uuid)}/read/${book.id}?p=${p}&from=${encodeURIComponent(backHash)}`;
        };
        if (last > 0) {
            const overlay = el("div", { class: "reader-dialog-overlay" });
            const panel = el("div", { class: "reader-dialog" });
            panel.append(el("p", { class: "reader-dialog-title", text: `「${book.title}」は読みかけです` }));
            const resumeBtn = el("button", { class: "reader-dialog-btn", type: "button", text: "続きから" });
            resumeBtn.addEventListener("click", () => { overlay.remove(); gotoVolume(last + 1); });
            const startBtn = el("button", { class: "reader-dialog-btn", type: "button", text: "最初から" });
            startBtn.addEventListener("click", () => { overlay.remove(); gotoVolume(1); });
            panel.append(resumeBtn, startBtn);
            overlay.append(panel);
            overlay.addEventListener("click", (e) => { if (e.target === overlay) overlay.remove(); });
            readerEl.append(overlay);
        } else {
            gotoVolume(1);
        }
    }

    // 19. 設定シート（R6）
    function openReaderSettings() {
        // 既存のオーバーレイが残っていれば除去
        const existing = readerEl.querySelector(".reader-settings-overlay");
        if (existing) { existing.remove(); return; }

        function closeSheet() {
            overlay.remove();
        }

        // ---- 設定行ヘルパ ----
        function settingRow(label, control) {
            return el("div", { class: "reader-settings-row" }, [
                el("span", { class: "reader-settings-label", text: label }),
                control,
            ]);
        }

        // 1. フル先読み（Tier3）トグル
        const tier3Check = el("input", {
            type: "checkbox",
            id: "rs-tier3",
            checked: readerPrefs().tier3Enabled ? true : false,
            onChange: (e) => {
                const v = e.target.checked;
                setReaderPref("tier3Enabled", v);
                engine.ctx.tier3Enabled = v;
                engine.setCurrentPage(cur);
            },
        });
        const tier3Label = el("label", { for: "rs-tier3", text: "フル先読み（Tier3）" });
        const tier3Row = settingRow("", el("div", { class: "reader-settings-toggle-wrap" }, [tier3Check, tier3Label]));

        // 2. キャッシュ上限プリセット
        const cacheLimits = [
            { label: "300 MB", bytes: 300 * 1024 * 1024 },
            { label: "600 MB", bytes: 600 * 1024 * 1024 },
            { label: "1 GB",   bytes: 1 * 1024 * 1024 * 1024 },
            { label: "2 GB",   bytes: 2 * 1024 * 1024 * 1024 },
        ];
        const currentLimit = readerPrefs().cacheLimitBytes;
        const cacheSelect = el("select", {
            class: "reader-settings-select",
            onChange: (e) => {
                const bytes = Number(e.target.value);
                setReaderPref("cacheLimitBytes", bytes);
                engine.ctx.cacheLimitBytes = bytes;
            },
        }, cacheLimits.map(({ label, bytes }) =>
            el("option", { value: String(bytes), text: label, selected: bytes === currentLimit ? true : false })
        ));
        const cacheLimitRow = settingRow("キャッシュ上限", cacheSelect);

        // 3. 終了時にキャッシュを消す
        const clearExitCheck = el("input", {
            type: "checkbox",
            id: "rs-clear-exit",
            checked: readerPrefs().clearCacheOnExit ? true : false,
            onChange: (e) => {
                setReaderPref("clearCacheOnExit", e.target.checked);
            },
        });
        const clearExitLabel = el("label", { for: "rs-clear-exit", text: "終了時にキャッシュを消す" });
        const clearExitRow = settingRow("", el("div", { class: "reader-settings-toggle-wrap" }, [clearExitCheck, clearExitLabel]));

        // 4. 読み方向（DB に書き戻し）
        const dirOptions = [
            { label: "左開き（ltr・左→右）", value: "ltr" },
            { label: "右開き（rtl・右→左 / 漫画）", value: "rtl" },
        ];
        const dirSelect = el("select", {
            class: "reader-settings-select",
            onChange: (e) => {
                direction = e.target.value;
                show(cur);
                postDirection(uuid, bookId, direction).catch(() => { toast("方向の保存に失敗しました"); });
            },
        }, dirOptions.map(({ label, value }) =>
            el("option", { value, text: label, selected: value === direction ? true : false })
        ));
        const dirRow = settingRow("読み方向", dirSelect);

        // 5. 今すぐキャッシュを消去
        const clearNowBtn = el("button", {
            class: "btn-secondary reader-settings-btn",
            type: "button",
            text: "今すぐキャッシュを消去",
            onClick: async () => {
                await clearAll();
                toast("キャッシュを消去しました");
            },
        });

        // 6. 閉じるボタン
        const closeBtn = el("button", {
            class: "btn-primary reader-settings-btn",
            type: "button",
            text: "閉じる",
            onClick: () => closeSheet(),
        });

        const sheet = el("div", { class: "reader-settings" }, [
            el("h2", { class: "reader-settings-title", text: "リーダー設定" }),
            tier3Row,
            cacheLimitRow,
            clearExitRow,
            dirRow,
            clearNowBtn,
            closeBtn,
        ]);

        const overlay = el("div", { class: "reader-settings-overlay" }, [sheet]);
        // 背景タップで閉じる
        overlay.addEventListener("click", (e) => {
            if (e.target === overlay) closeSheet();
        });

        readerEl.append(overlay);
    }

    // 20. 初期描画
    await show(cur);
}

// ---- ユーティリティ ----------------------------------------------------------

function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/// リーダーの「戻る」先 hash を解決する（G17 T2）。
/// query.from は books.js openAt() が付与した、リーダーを開いた時点の一覧 hash
/// （絞り込み・検索・並び順・facet 選択を含む）。app.js の parseRoute() が hash の
/// 各クエリ値をすでに一段 decodeURIComponent 済みなので、ここで再デコードしてはいけない
/// （二重デコードすると検索語に含まれる "%" や "&" を含む値が壊れる — 実測で確認済み）。
/// from が無い（直リンク/旧リンク）か想定外の形なら、従来どおり #/lib/<uuid> にフォールバックする。
export function resolveBackHash(uuid, query) {
    const fallback = `#/lib/${encodeURIComponent(uuid)}`;
    const from = query && query.from;
    if (typeof from !== "string" || from.length === 0) return fallback;
    try {
        // "#/lib/<何か>"（クエリ付き可）の形だけを受け付ける安全弁。
        if (/^#\/lib\/[^/]+(\?.*)?$/.test(from)) return from;
    } catch {
        // 想定外の値は下のフォールバックへ
    }
    return fallback;
}
