// SPDX-License-Identifier: MIT
// StackNest Web — リーダー画面（タップ/スワイプ/キーボードナビ、見開き、progress 書き戻し）。
// Task R4。

import { fetchManifest, fetchPageBlob, postProgress, postDirection, postPageLayout, fetchAdjacent, UnauthorizedError, NetworkError } from "./api.js";
import { deleteBook, clearAll, purgeExpired } from "./idb.js";
import { PrefetchEngine } from "./prefetch.js";
import { readerPrefs, setReaderPref } from "./prefs.js";
import { spring } from "./anim.js";

// 同時に存在するリーダーは 1 つ。再マウント前に前インスタンスを確実に teardown する。
let activeReaderTeardown = null;

// ---- G17 Pack C: ドラッグめくり定数 -------------------------------------------
const DRAG_HYSTERESIS = 10;      // px。これ未満は方向未確定（タップ/縦スクロールと非衝突）
const DRAG_FLICK_VELOCITY = 500; // px/s。これを超えたら距離未達でもフリックとして確定
const DRAG_DECEL = 0.998;        // apple-design のモーメンタム射影に使う減衰率
// D8 device fix: ドラッグ確定後この時間内に来たタップゾーン click は「指を離した位置で iOS が合成した
// click」とみなして無視する。iOS Safari は pointerup 後に compat click を合成し、それが右/左タップゾーン
// （画面幅の 1/3）で発火すると go() が古い cur で逆方向送りをして、進行中の正しいドラッグ確定を
// cancelActiveDrag が打ち消してしまう（＝smoke C1「左→右で前ページに戻る」の真因・iPhone 特異的）。
// 既存の suppressClick(capture 握り潰し)は pointer capture 下の合成 click に対し WebKit で確実に効かない
// ため、デバイス非依存の時間ガードで二重防御する。スプリング(response 0.32s)＋合成 click 遅延を包含。
const TAP_AFTER_DRAG_GUARD_MS = 450;

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

/// ラバーバンド抵抗（apple-design 準拠）。overshoot=境界を超えて引っ張った量、
/// dimension=基準寸法（ここではステージ幅 px）。境界を超えるほど戻り値の伸びが鈍る。
export function rubberband(overshoot, dimension, constant = 0.55) {
    if (dimension <= 0) return 0;
    return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));
}

/// モーメンタム射影（apple-design 準拠）。velocity は px/s。d≈0.998 の指数減衰積分。
/// 「離した位置 + この射影量」が着地予測点になる（v²/2a のような教科書物理ではなく
/// Apple の Designing Fluid Interfaces が示す指数減衰式）。
export function projectMomentum(velocity, d = DRAG_DECEL) {
    return (velocity / 1000) * d / (1 - d);
}

/// リリース着地の判定（純関数・テスト可能）。
/// D8 fix: 指を離す瞬間の微小な逆方向ジッタで velocity の符号が反転し、正味は前方ドラッグなのに
/// 逆向きフリックが誤発火して「前のページへ戻る」不具合を根絶する。velocity は**ドラッグ変位
/// (trackX) と同符号のときだけ有効**とし（逆符号のリリース速度は 0 扱い＝無視）、モーメンタム射影
/// とフリック閾値の双方に適用する。これによりページ送りは常にユーザーがドラッグした向きにしか
/// 起きない。50% 射影ルール（距離）は保持。
/// trackX 符号: 負=右送り(right)方向へドラッグ / 正=左送り(left)方向へドラッグ。
///
/// 既知の割り切り（review #1・意図的）: 「途中まで一方向へドラッグ→正味 trackX が反転する前に逆へ
/// 強くフリック」した稀なケースは、velocity がドラッグ変位と逆符号なので無視され cancel（現ページへ
/// スナップバック）になる。これは「表示位置＝ドラッグ変位を信頼し、velocity 単独では逆送りしない」
/// という本 fix の設計そのもの（velocity 単独を信じると狙いのジッタ誤送りが復活する）。ユーザーは
/// もう一度ドラッグすれば送れるため許容。trackX===0 での release も同様に cancel。
export function decideDragSettle({ trackX, velocity, width, forceCancel = false }) {
    if (forceCancel) return { action: "cancel", flick: false };
    const dir = Math.sign(trackX);
    const eff = ((dir < 0 && velocity < 0) || (dir > 0 && velocity > 0)) ? velocity : 0;
    const projected = trackX + projectMomentum(eff);
    const flick = Math.abs(eff) > DRAG_FLICK_VELOCITY;
    if (projected < -width * 0.5 || eff < -DRAG_FLICK_VELOCITY) return { action: "right", flick };
    if (projected >  width * 0.5 || eff >  DRAG_FLICK_VELOCITY) return { action: "left", flick };
    return { action: "cancel", flick: false };
}

// ---- メイン export -----------------------------------------------------------

/// リーダー画面を描画する。
/// deps: { el, render, toast, appEl, onLibraryUnshared }
/// query: parseRoute() の query（p=uiPage を含む）
export async function renderReader(uuid, bookId, query, deps) {
    const { el, toast, appEl, onLibraryUnshared, cancelActiveTransition } = deps;
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
    // G17 Pack C: 表示は「現在 view」を包む .reader-view（curView）単位で管理する。
    // ドラッグ中はこれに加えて隣接 view（左右）が一時的に並ぶ（dragState 内で管理）。
    let curView = null;        // 現在表示中の .reader-view（tapLeft の直前に挿入）
    let curViewURLs = [];      // curView 内 <img> の objectURL

    function destroyCurView() {
        if (curView) { curView.remove(); curView = null; }
        for (const u of curViewURLs) URL.revokeObjectURL(u);
        curViewURLs = [];
    }

    /// 見開き/単頁の表示ノードを構築する（show() とドラッグ隣接 view 読み込みで共用）。
    function buildViewNode(imgs, isSpread, dir) {
        if (isSpread) {
            const spreadWrap = el("div", { class: "reader-spread" });
            if (dir === "rtl") {
                // 右に小さい apiIndex = imgs[0] が右、imgs[1] が左
                spreadWrap.append(imgs[1], imgs[0]);
            } else {
                spreadWrap.append(imgs[0], imgs[1]);
            }
            return spreadWrap;
        }
        return imgs[0];
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

    // 複数ページ（見開き）をまとめてデコードする。Promise.all は一部が reject すると成功分の
    // 戻り値を捨てるため、作成済み objectURL が revoke されずリークする（Codex Low2）。
    // allSettled で受け、失敗があれば成功済みの URL を revoke してから throw する。
    async function decodeAll(indices) {
        const results = await Promise.allSettled(indices.map((i) => makeDecodedImg(i)));
        const ok = [];
        let err = null;
        for (const r of results) {
            if (r.status === "fulfilled") ok.push(r.value);
            else err = err || r.reason;
        }
        if (err) { for (const m of ok) URL.revokeObjectURL(m.url); throw err; }
        return ok;
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

    // D8 device fix: 直近のドラッグ確定時刻（Date.now）。onDragPointerEnd で更新し、タップゾーンの
    // click ハンドラがこの直後の合成 click を無視するのに使う。
    let lastDragCommitAt = 0;
    /// タップゾーン click を、ドラッグ確定直後の合成 click なら無視するようにラップする。
    const guardTap = (fn) => () => {
        if (Date.now() - lastDragCommitAt < TAP_AFTER_DRAG_GUARD_MS) return;
        fn();
    };

    // タップゾーン（透明操作領域）
    const tapLeft = el("div", { class: "tapzone left", onClick: guardTap(() => go(physicalToDir("left", direction))) });
    const tapCenter = el("div", { class: "tapzone center", onClick: guardTap(() => toggleChrome()) });
    const tapRight = el("div", { class: "tapzone right", onClick: guardTap(() => go(physicalToDir("right", direction))) });

    // タップゾーンと読み込みインジケータを stage に追加
    stageEl.append(tapLeft, tapCenter, tapRight, loadingEl);

    const readerEl = el("div", { class: "reader" }, [stageEl, topChrome, bottomChrome]);

    // appEl に直接 append（render() は使わない）
    // #app の旧画面 DOM をクリアしてからマウント（toast-host は #app 外なので消えない）。
    // Pack B review Important #1: 進行中の push/pop 遷移があれば先に確定させる。これを
    // 怠ると、遷移中の .nav-layer をここで剥がした後に遅れて finish() が insertBefore で
    // throw する（リーダー URL へ直接ランディングした場合に発生）。
    cancelActiveTransition?.();
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

        // G17 Pack C: 進行中のドラッグ/リリーススプリングがあれば破棄する
        // （キーボード/スライダー/タップが drag と競合した場合の防御。通常のドラッグ
        // 確定パスは commitDrag() 側で自ら破棄してから show() を呼ぶので、ここは
        // 二重破棄しても安全な no-op になる）。
        cancelActiveDrag();

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
            made = await decodeAll(indices);
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

        // 新しい view を構築してから古い curView と差し替える（用意ができるまで
        // 旧ページを表示し続け、読み込み中の一瞬だけ黒画面になるのを避ける — 既存挙動を維持）。
        const isSpread = spread && made.length === 2;
        const content = buildViewNode(made.map((m) => m.img), isSpread, direction);
        const newView = el("div", { class: "reader-view" }, [content]);
        destroyCurView();
        stageEl.insertBefore(newView, tapLeft);
        curView = newView;
        curViewURLs = made.map((m) => m.url);

        // 先読みエンジンに現在ページを通知
        engine.setCurrentPage(cur);

        // progress を debounce 送信
        scheduleProgress(cur);
    }

    // 12. スライダー操作
    sliderEl.addEventListener("input", () => {
        show(Number(sliderEl.value) - 1);
    });

    // 13. スワイプ（タッチ・フォールバック）
    // G17 Pack C: 通常時は下の 13b ポインタドラッグが 1:1 追従＋モーメンタムでページ送りを
    // 担当するため、ここでの go() 発火は prefers-reduced-motion: reduce のときだけに絞る
    // （13b はドラッグ追従を丸ごと無効化するため、reduced-motion では旧来のこのフォールバックが
    // 唯一のタッチスワイプ導線になる。両方を常時有効にすると同一ジェスチャで二重ページ送りになる）。
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
        if (!reducedMotion) return;   // 通常時は 13b のポインタドラッグに委ねる
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

    // 13b. ドラッグめくり（ポインタイベント・G17 Pack C）
    // 1:1 追従＋速度履歴からのモーメンタム射影＋端でのラバーバンド＋触覚。
    // anim.js の手組みスプリングを再利用（外部ライブラリ不使用）。
    // prefers-reduced-motion: reduce のときは一切のドラッグ追従・spring を発生させない
    // （このメディアクエリは reader 起動時に一度だけ評価。実行中の設定変更までは追わない —
    //  他の Pack A/B 実装と同じ規約）。
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    let dragState = null;      // アクティブなドラッグの状態（非ドラッグ中は null）
    let releaseSpring = null;  // リリース後の着地/戻りスプリング（token）
    let settlingDs = null;     // releaseSpring が現在動かしている ds（中断時の後始末に必要）
    let suppressClick = false; // 確定ドラッグ直後の click（tapzone）を握り潰すフラグ

    /// 進行中のドラッグ/リリーススプリングを即座に破棄する（DOM 上の隣接 view を消し、
    /// objectURL を revoke する）。curView 自体には触れない（show() 側が管理する）。
    function destroyDrag(ds) {
        if (!ds) return;
        ds.alive = false;
        if (ds.leftView) { ds.leftView.remove(); ds.leftView = null; }
        if (ds.rightView) { ds.rightView.remove(); ds.rightView = null; }
        for (const u of ds.leftURLs) URL.revokeObjectURL(u);
        for (const u of ds.rightURLs) URL.revokeObjectURL(u);
        ds.leftURLs = [];
        ds.rightURLs = [];
        if (curView) curView.style.willChange = "";
    }

    /// show() や teardown() から呼ぶ防御的クリーンアップ。進行中のドラッグ/スプリングを
    /// すべて破棄し、curView を translateX(0) の静止状態に戻す。
    /// releaseSpring.cancel() は onDone を呼ばない（anim.js の契約）ため、着地アニメ中に
    /// 割り込まれた場合は settlingDs 経由で隣接 view の破棄を自前で行う必要がある
    /// （でないと DOM/objectURL がリークする）。
    function cancelActiveDrag() {
        if (releaseSpring) { releaseSpring.cancel(); releaseSpring = null; }
        if (settlingDs) { destroyDrag(settlingDs); settlingDs = null; }
        if (dragState) { destroyDrag(dragState); dragState = null; }
        if (curView) curView.style.transform = "";
    }

    /// trackX（px）を curView・左右隣接 view の transform に反映する。
    /// leftView は -width 起点、rightView は +width 起点（G17 Pack C の設計：
    /// 3 枠のトラックを 1 つのスカラー trackX で一体に動かす）。
    function setTrackTransforms(ds, trackX) {
        if (curView) curView.style.transform = trackX ? `translateX(${trackX}px)` : "";
        if (ds.leftView) ds.leftView.style.transform = `translateX(${trackX - ds.width}px)`;
        if (ds.rightView) ds.rightView.style.transform = `translateX(${trackX + ds.width}px)`;
    }

    /// dx（生の指の移動量）を、端でのラバーバンドを適用したトラック位置に変換する。
    function computeTrackX(dx, ds) {
        const w = ds.width;
        if (dx > 0 && ds.atLeftEdge) return rubberband(dx, w);
        if (dx < 0 && ds.atRightEdge) return -rubberband(-dx, w);
        return dx;
    }

    /// 直近の位置履歴（約100ms窓）からリリース速度（px/s）を計算する。
    function computeDragVelocity(ds) {
        const h = ds.history;
        if (h.length < 2) return 0;
        const first = h[0], last = h[h.length - 1];
        const dt = (last.t - first.t) / 1000;
        if (dt <= 0) return 0;
        return (last.x - first.x) / dt;
    }

    /// 隣接 view（左右いずれか）へ非同期にデコード済み画像を読み込む。ドラッグが既に
    /// 終了/差し替わっていれば（ds.alive===false）objectURL だけ revoke して何もしない
    /// （view 要素はすでに DOM から外れているので append しても無害だが、リークは防ぐ）。
    async function loadNeighborInto(viewEl, apiIndex, ds, side) {
        try {
            const indices = pagesForView(apiIndex, spread, pageCount, overrides);
            const made = await decodeAll(indices);
            if (!ds.alive) { for (const m of made) URL.revokeObjectURL(m.url); return; }
            const urls = made.map((m) => m.url);
            const content = buildViewNode(made.map((m) => m.img), spread && made.length === 2, direction);
            viewEl.append(content);
            if (side === "left") ds.leftURLs = urls; else ds.rightURLs = urls;
        } catch {
            // 読み込み失敗: プレースホルダ（黒背景）のまま。ドラッグ自体は継続させる
            // （リリース時に show() が改めて正規のフェッチ/エラーハンドリングを行う）。
        }
    }

    /// ヒステリシス確定の瞬間に呼ばれる。ステージ幅・隣接 apiIndex（T6b override 込みの
    /// pagesForView/step と整合）を確定し、左右の隣接 view を DOM に並べて非同期読み込みを開始する。
    function beginHorizontalDrag(ds) {
        if (releaseSpring) { releaseSpring.cancel(); releaseSpring = null; }
        ds.width = stageEl.clientWidth || 1;
        // 物理右 = physicalToDir("right", direction) の指すページ（ltr:+1／rtl:-1）。
        // タップゾーン（tapRight）・既存タッチスワイプと符号を完全一致させる。
        ds.rightDir = physicalToDir("right", direction);
        ds.leftDir = -ds.rightDir;
        ds.rightIdx = step(cur, ds.rightDir, spread, pageCount, overrides);
        ds.leftIdx = step(cur, ds.leftDir, spread, pageCount, overrides);
        ds.atRightEdge = ds.rightIdx === cur;
        ds.atLeftEdge = ds.leftIdx === cur;
        ds.leftView = el("div", { class: "reader-view" });
        ds.rightView = el("div", { class: "reader-view" });
        stageEl.insertBefore(ds.leftView, tapLeft);
        stageEl.insertBefore(ds.rightView, tapLeft);
        if (curView) curView.style.willChange = "transform";
        ds.leftView.style.willChange = "transform";
        ds.rightView.style.willChange = "transform";
        setTrackTransforms(ds, 0);
        if (!ds.atRightEdge) loadNeighborInto(ds.rightView, ds.rightIdx, ds, "right");
        if (!ds.atLeftEdge) loadNeighborInto(ds.leftView, ds.leftIdx, ds, "left");
    }

    /// リリース時、trackX を 0（元の位置）へスプリングで戻す/送る共通ヘルパ。
    /// bounce=true のときだけ減衰比を下げてわずかにオーバーシュートさせる
    /// （apple-design: フリック＝運動量を伴うジェスチャのときだけバウンスを許す）。
    function animateTrack(ds, targetTrackX, velocity, bounce, onDone) {
        if (releaseSpring) { releaseSpring.cancel(); releaseSpring = null; }
        if (settlingDs && settlingDs !== ds) { destroyDrag(settlingDs); }
        settlingDs = ds;
        releaseSpring = spring({
            from: ds.trackX,
            to: targetTrackX,
            velocity,
            damping: bounce ? 0.8 : 1,
            response: 0.32,   // anim.js が安定確認済みの 0.02–0.35 の範囲内
            onUpdate: (x) => { ds.trackX = x; setTrackTransforms(ds, x); },
            onDone: () => { releaseSpring = null; settlingDs = null; onDone(); },
        });
    }

    /// このジェスチャで読み込み済みの隣接 view を現在 view に「昇格」させる。show() を経由せず
    /// 再フェッチ/デコード（＝黒いローディングの一瞬のちらつき）を避けるのが目的。状態同期
    /// （cur・スライダー/カウンタ・T6b ラベル・先読み・progress）は show() と同一内容を行う。
    function promoteView(ds, side, newIdx) {
        const view = side === "right" ? ds.rightView : ds.leftView;
        const urls = side === "right" ? ds.rightURLs : ds.leftURLs;
        renderToken++;                 // 万一 in-flight な show() があれば無効化
        cur = newIdx;
        // 昇格する view/urls を ds から切り離す（destroyDrag に消させない・revoke させない）。
        if (side === "right") { ds.rightView = null; ds.rightURLs = []; }
        else { ds.leftView = null; ds.leftURLs = []; }
        destroyDrag(ds);               // 反対側隣接 view の掃除＋willChange 解除
        destroyCurView();              // 旧 curView 破棄（objectURL revoke）
        view.style.transform = "";     // 着地アニメ終了時点で既に translateX(0)（中央）
        view.style.willChange = "";
        curView = view;
        curViewURLs = urls;
        const uiPage = cur + 1;
        sliderEl.value = String(uiPage);
        sliderEl.style.direction = (direction === "rtl") ? "rtl" : "ltr";
        counterEl.textContent = `${uiPage} / ${pageCount}`;
        titleSpan.textContent = `ページ ${uiPage} / ${pageCount}`;
        updatePageLayoutLabel();
        engine.setCurrentPage(cur);
        scheduleProgress(cur);
    }

    /// ページ送りを確定させる: target(±width) までスプリングし、完了後、読み込み済みの隣接
    /// view を昇格させる（黒ローディングのちらつき回避）。隣接が未ロード/失敗のときのみ従来の
    /// show(newIdx) にフォールバック（正規のフェッチ/エラーハンドリング）する。
    function commitDrag(ds, side, velocity, flick) {
        const w = ds.width;
        const target = side === "right" ? -w : w;
        const newIdx = side === "right" ? ds.rightIdx : ds.leftIdx;
        animateTrack(ds, target, velocity, flick, () => {
            const view = side === "right" ? ds.rightView : ds.leftView;
            const urls = side === "right" ? ds.rightURLs : ds.leftURLs;
            if (view && urls.length > 0 && view.firstChild) {
                promoteView(ds, side, newIdx);
            } else {
                destroyDrag(ds);
                destroyCurView();
                show(newIdx);
            }
        });
    }

    /// pointerup/pointercancel で呼ぶ着地判定。判定ロジックは decideDragSettle（純関数）に委譲し、
    /// ここは端処理・触覚・commitDrag/スナップバックの副作用のみを担う。
    function settleDrag(ds, forceCancel) {
        const velocity = forceCancel ? 0 : computeDragVelocity(ds);
        const d = decideDragSettle({ trackX: ds.trackX, velocity, width: ds.width, forceCancel });

        if (d.action === "right") {
            if (ds.atRightEdge) {
                navigator.vibrate?.(10);
                const toEnd = ds.rightDir > 0;
                animateTrack(ds, 0, 0, false, () => { destroyDrag(ds); if (toEnd) showEndOfBookDialog(); });
                return;
            }
            navigator.vibrate?.(10);
            commitDrag(ds, "right", velocity, d.flick);
            return;
        }
        if (d.action === "left") {
            if (ds.atLeftEdge) {
                navigator.vibrate?.(10);
                const toEnd = ds.leftDir > 0;
                animateTrack(ds, 0, 0, false, () => { destroyDrag(ds); if (toEnd) showEndOfBookDialog(); });
                return;
            }
            navigator.vibrate?.(10);
            commitDrag(ds, "left", velocity, d.flick);
            return;
        }
        // cancel → 元の位置へ戻す。端に突き当たっていた場合のみ触覚を鳴らす。
        const trackXNow = ds.trackX;
        if ((trackXNow > 0 && ds.atLeftEdge) || (trackXNow < 0 && ds.atRightEdge)) navigator.vibrate?.(10);
        animateTrack(ds, 0, velocity, false, () => destroyDrag(ds));
    }

    if (!reducedMotion) {
        stageEl.addEventListener("pointerdown", (e) => {
            if (e.pointerType === "mouse" && e.button !== 0) return;   // 主ボタンのみ
            if (dragState || releaseSpring) return;                   // 多重ジェスチャ/着地中は無視
            suppressClick = false;
            dragState = {
                pointerId: e.pointerId,
                startX: e.clientX, startY: e.clientY,
                committed: false,
                trackX: 0,
                width: 0,
                history: [{ x: e.clientX, t: e.timeStamp }],
                leftView: null, rightView: null,
                leftURLs: [], rightURLs: [],
                leftIdx: cur, rightIdx: cur,
                leftDir: 0, rightDir: 0,
                atLeftEdge: true, atRightEdge: true,
                alive: true,
            };
            stageEl.setPointerCapture(e.pointerId);
        });

        stageEl.addEventListener("pointermove", (e) => {
            const ds = dragState;
            if (!ds || e.pointerId !== ds.pointerId) return;
            const x = e.clientX, y = e.clientY;
            if (!ds.committed) {
                const dx = x - ds.startX, dy = y - ds.startY;
                if (Math.abs(dx) < DRAG_HYSTERESIS && Math.abs(dy) < DRAG_HYSTERESIS) return;
                if (Math.abs(dy) > Math.abs(dx)) {
                    // 縦方向優勢 → このジェスチャはページ送りにしない（縦スクロール等に譲る）
                    dragState = null;
                    return;
                }
                ds.committed = true;
                beginHorizontalDrag(ds);
            }
            ds.history.push({ x, t: e.timeStamp });
            while (ds.history.length > 1 && e.timeStamp - ds.history[0].t > 100) ds.history.shift();
            ds.trackX = computeTrackX(x - ds.startX, ds);
            setTrackTransforms(ds, ds.trackX);
            e.preventDefault();
        });

        const onDragPointerEnd = (forceCancel) => (e) => {
            const ds = dragState;
            if (!ds || e.pointerId !== ds.pointerId) return;
            dragState = null;
            try { stageEl.releasePointerCapture(e.pointerId); } catch {}
            if (!ds.committed) return;   // ヒステリシス未確定＝タップ相当。click を正常発火させる
            suppressClick = true;
            lastDragCommitAt = Date.now();   // D8 device fix: 直後の合成 click を guardTap で無視する
            settleDrag(ds, forceCancel);
        };
        stageEl.addEventListener("pointerup", onDragPointerEnd(false));
        stageEl.addEventListener("pointercancel", onDragPointerEnd(true));

        // 確定ドラッグ直後に tapzone の click（go()/toggleChrome()）が誤発火しないよう、
        // capture フェーズで握り潰す（capture 段階で stopPropagation すると target の
        // bubble リスナーまで到達しない）。
        stageEl.addEventListener("click", (e) => {
            if (suppressClick) { e.stopPropagation(); e.preventDefault(); suppressClick = false; }
        }, true);
    }

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
        if (document.hidden) {
            flushProgress(cur);
            // G17 Pack C review: pointerup/pointercancel が来ないまま非表示になった場合の安全網
            // （進行中ドラッグが mid-transform で残り、次入力まで新規ドラッグがブロックされるのを防ぐ）。
            cancelActiveDrag();
        }
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
        cancelActiveDrag();   // G17 Pack C: 進行中のドラッグ/リリーススプリング・隣接 view を破棄
        destroyCurView();
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
