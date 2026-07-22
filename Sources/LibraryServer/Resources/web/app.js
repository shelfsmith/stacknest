// SPDX-License-Identifier: MIT
// StackNest Web クライアント — SPA・hash ルーティング。
// Task 6: 基盤 + ペアリング + ライブラリ一覧（books 画面は Task 7。今は「準備中」）。

import {
    api, apiJSON, hasDeviceToken, saveDeviceToken, clearDeviceToken,
    listLibraries, unlockLibrary, UnauthorizedError, NetworkError,
} from "./api.js";
import { renderBooks, buildBooksSkeleton } from "./books.js";
import { renderReader, resolveBackHash } from "./reader.js";
import { stopLiveSync } from "./livesync.js";
import { spring } from "./anim.js";

const appEl = () => document.getElementById("app");
const backBtn = () => document.getElementById("back-btn");
const titleEl = () => document.getElementById("app-title");

// ---- 小さな DOM ヘルパ（テンプレートライブラリ不使用） -------------------------

/// 要素生成。attrs は属性/プロパティ、children は文字列か Node。
function el(tag, attrs = {}, children = []) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (v === false || v === null || v === undefined) continue;
        if (k === "class") node.className = v;
        else if (k === "text") node.textContent = v;
        else if (k.startsWith("on") && typeof v === "function") {
            node.addEventListener(k.slice(2).toLowerCase(), v);
        } else node.setAttribute(k, v === true ? "" : String(v));
    }
    for (const c of [].concat(children)) {
        if (c === null || c === undefined || c === false) continue;
        node.append(c.nodeType ? c : document.createTextNode(String(c)));
    }
    return node;
}

function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

// ---- 空間ナビゲーション遷移（G17 Pack B） -----------------------------------
// 画面（pair/libraries/lib）単位の push/pop を判定し、深さが増えるルート遷移は
// 「前進」（新ビューが右からスライドイン・旧ビューは左へ少しシフト＋フェード）、
// 深さが減る遷移は「戻り」（対称に旧ビューが右へスライドアウト）としてアニメーションする。
// 同一スクリーン内のフィルタ/ページ/ソート変更（route() の再呼び出し）はスクリーンキーが
// 変わらないため無アニメーション（従来どおりの即時差し替え）。
//
// reader（フルスクリーン没入表示）は appEl() を直接操作し render() を経由しない設計
// （reader.js 側の既存方針）なので、このトランジション機構の対象外
// （lib ⇄ read の押し込み/引き戻しは reader 自身の演出のまま・本 Pack のファイル範囲外）。

/// ルートからスクリーンの識別キーを作る。フィルタ用の query は含めない
/// （同じ画面内の絞り込み変更をスクリーン遷移として扱わないため）。
function screenKeyFor(r) {
    switch (r.name) {
        case "pair": return "pair";
        case "lib": return `lib:${r.uuid}`;
        case "read": return `read:${r.uuid}:${r.bookId}`;
        case "libraries":
        default: return "libraries";
    }
}

/// ルートの「深さ」。深さが増える→前進、減る→戻り、の判定に使う。
function screenDepthFor(r) {
    switch (r.name) {
        case "lib": return 1;
        case "read": return 2;
        case "pair":
        case "libraries":
        default: return 0;
    }
}

let currentScreenKey = null;   // 直近に render() で確定したスクリーンキー
let currentScreenDepth = 0;
const scrollPositions = new Map();  // screenKey -> 離脱時の window.scrollY
let pendingNav = null;              // route() が計算し、次の render() が一度だけ消費する
let activeCancelTransition = null;  // 実行中のアニメーション遷移を即座に確定させる関数

/// route() の冒頭で呼ぶ。今回のルートがどのスクリーンで、前回スクリーンと比べて
/// 前進/戻り/無変化のどれかを判定し、次の render() 呼び出しに使わせる。
function prepareNavigation(r) {
    const key = screenKeyFor(r);
    const depth = screenDepthFor(r);
    if (currentScreenKey === null || key === currentScreenKey) {
        pendingNav = { type: "none", key, depth };
        return;
    }
    pendingNav = { type: depth < currentScreenDepth ? "back" : "forward", key, depth };
}

/// 現在このスクリーンキーへの遷移が「新規エントリ」（フィルタ変更等ではなく画面自体の
/// 切替）かどうか。books.js の初回スケルトン表示要否の判定に使う（renderLib 内）。
function isFreshEntry(key) { return currentScreenKey !== key; }

function cancelActiveTransition() {
    if (activeCancelTransition) {
        const fn = activeCancelTransition;
        activeCancelTransition = null;
        fn();
    }
}

/// 前進/戻り遷移をアニメーションする。old（現在 main の子）を .nav-layer に包んで残し、
/// new（今回の content）も .nav-layer に包んで重ね、rAF スプリングで transform/opacity を
/// 動かす。完了後は new を通常の main 直下の子へ戻し（unwrap）、old 側のラッパを除去する。
/// 途中で割り込まれたら（cancelActiveTransition）即座に確定させ、DOM を単純な状態に戻す。
function runScreenTransition(main, newContent, nav) {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const startScrollY = window.scrollY;
    const targetScrollY = nav.type === "back" ? (scrollPositions.get(nav.key) || 0) : 0;

    const oldLayer = el("div", { class: "nav-layer" });
    oldLayer.append(...Array.from(main.childNodes)); // 現在の main の子を丸ごと退避（main は空になる）
    const newLayer = el("div", { class: "nav-layer" });
    newLayer.append(newContent);
    // この時点で main は空。[oldLayer, newLayer] の順に積む
    // （このあと render() 呼び出し元が appEl() に直接 append する物、例えば
    //  promptUnlock のロック解除モーダルは、この後ろに追加されるため影響しない）。
    main.append(oldLayer, newLayer);

    oldLayer.scrollTop = Math.max(0, startScrollY);
    newLayer.scrollTop = Math.max(0, targetScrollY);

    let done = false;
    function finish() {
        if (done) return;
        done = true;
        // newContent を newLayer から main 直下へ戻す（既存の他の子の前に挿入）。
        main.insertBefore(newContent, oldLayer);
        oldLayer.remove();
        newLayer.remove();
        window.scrollTo(0, targetScrollY);
        activeCancelTransition = null;
    }

    if (reduced) {
        // reduced-motion: transform 無しの短いオパシティ クロスフェード。
        newLayer.style.opacity = "0";
        newLayer.style.zIndex = "2";
        oldLayer.style.opacity = "1";
        oldLayer.style.zIndex = "1";
        const tok = spring({
            from: 0, to: 1, damping: 1, response: 0.18,
            onUpdate: (v) => {
                newLayer.style.opacity = String(v);
                oldLayer.style.opacity = String(1 - v);
            },
            onDone: finish,
        });
        activeCancelTransition = () => { tok.cancel(); finish(); };
        return;
    }

    // フルスライド。前進/戻りで初期値と重なり順を対称にする。
    let oldTok, newTok;
    let settledCount = 0;
    const maybeFinish = () => { settledCount += 1; if (settledCount >= 2) finish(); };

    if (nav.type === "forward") {
        newLayer.style.zIndex = "2";
        oldLayer.style.zIndex = "1";
        newLayer.style.transform = "translateX(100%)";
        newLayer.style.opacity = "1";
        oldLayer.style.transform = "translateX(0%)";
        oldLayer.style.opacity = "1";
        oldTok = spring({
            from: 0, to: -30, damping: 1, response: 0.35,
            onUpdate: (v) => {
                oldLayer.style.transform = `translateX(${v}%)`;
                oldLayer.style.opacity = String(1 - Math.min(1, Math.abs(v) / 30) * 0.6);
            },
            onDone: maybeFinish,
        });
        newTok = spring({
            from: 100, to: 0, damping: 1, response: 0.35,
            onUpdate: (v) => { newLayer.style.transform = `translateX(${v}%)`; },
            onDone: maybeFinish,
        });
    } else {
        // back: 前進の対称形（現在の最前面ビューが右へ抜け、奥のビューが定位置へ戻る）。
        oldLayer.style.zIndex = "2";
        newLayer.style.zIndex = "1";
        oldLayer.style.transform = "translateX(0%)";
        oldLayer.style.opacity = "1";
        newLayer.style.transform = "translateX(-30%)";
        newLayer.style.opacity = "0.4";
        oldTok = spring({
            from: 0, to: 100, damping: 1, response: 0.35,
            onUpdate: (v) => { oldLayer.style.transform = `translateX(${v}%)`; },
            onDone: maybeFinish,
        });
        newTok = spring({
            from: -30, to: 0, damping: 1, response: 0.35,
            onUpdate: (v) => {
                newLayer.style.transform = `translateX(${v}%)`;
                newLayer.style.opacity = String(1 - Math.min(1, Math.abs(v) / 30) * 0.6);
            },
            onDone: maybeFinish,
        });
    }

    activeCancelTransition = () => { oldTok.cancel(); newTok.cancel(); finish(); };
}

/// 画面差し替え。タイトルと戻るボタンの表示は常に即時反映する。
/// pendingNav（route() が計算した前進/戻り/無変化）を一度だけ消費し、
/// 前進/戻りならアニメーション遷移、それ以外（無変化・初回）は従来どおり即時差し替え。
function render(title, content, { showBack = false } = {}) {
    titleEl().textContent = title;
    backBtn().hidden = !showBack;
    const main = appEl();
    const nav = pendingNav;
    pendingNav = null; // 一度だけ消費

    // 前の遷移が残っていれば、素の clear()/新しい遷移のどちらであっても先に即確定させる
    // （.nav-layer が main の子として残ったまま clear() すると、遅れて firing する
    //  在り処不明の finish() が insertBefore で例外を投げるため必須）。
    cancelActiveTransition();

    if (!nav || nav.type === "none") {
        clear(main);
        main.append(content);
        main.scrollTop = 0;
        if (nav) { currentScreenKey = nav.key; currentScreenDepth = nav.depth; }
        return;
    }

    if (currentScreenKey !== null) scrollPositions.set(currentScreenKey, window.scrollY);
    runScreenTransition(main, content, nav);
    currentScreenKey = nav.key;
    currentScreenDepth = nav.depth;
}

// ---- トースト ---------------------------------------------------------------

let toastTimer = null;
function toast(message, { actionLabel, onAction } = {}) {
    const host = document.getElementById("toast-host");
    clear(host);
    if (toastTimer) { clearTimeout(toastTimer); toastTimer = null; }
    const children = [el("span", { class: "toast-msg", text: message })];
    if (actionLabel && onAction) {
        children.push(el("button", {
            class: "toast-action", type: "button", text: actionLabel,
            onClick: () => { clear(host); if (toastTimer) clearTimeout(toastTimer); onAction(); },
        }));
    }
    host.append(el("div", { class: "toast", role: "status" }, children));
    // アクション付きトーストは自動で消さない（再試行を待つ）。
    if (!actionLabel) toastTimer = setTimeout(() => clear(host), 4000);
}

// ---- ルーティング -----------------------------------------------------------

/// hash を {name, params} に正規化。例: "#/lib/abc?page=2" → {name:"lib", uuid:"abc", query:{page:"2"}}
function parseRoute() {
    const raw = location.hash.replace(/^#\/?/, "");
    const [pathPart, queryPart] = raw.split("?");
    const segments = pathPart.split("/").filter(Boolean);
    const query = {};
    if (queryPart) {
        for (const pair of queryPart.split("&")) {
            const [k, v = ""] = pair.split("=");
            if (k) query[decodeURIComponent(k)] = decodeURIComponent(v);
        }
    }
    if (segments[0] === "lib" && segments[1] && segments[2] === "read" && segments[3]) {
        return { name: "read", uuid: decodeURIComponent(segments[1]), bookId: Number(segments[3]), query };
    }
    if (segments[0] === "lib" && segments[1]) {
        return { name: "lib", uuid: decodeURIComponent(segments[1]), query };
    }
    if (segments[0] === "pair") return { name: "pair", query };
    return { name: "libraries", query };
}

async function route() {
    const r = parseRoute();
    if (r.name !== "lib") stopLiveSync();
    // 未ペアリングなら（pair 画面以外は）ペアリングへ誘導。
    if (!hasDeviceToken() && r.name !== "pair") {
        location.hash = "#/pair";
        return;
    }
    prepareNavigation(r); // 次の render() 呼び出し用に前進/戻り/無変化を計算しておく
    try {
        switch (r.name) {
            case "pair": return renderPair();
            case "read": return await renderReader(r.uuid, r.bookId, r.query, readerDeps);
            case "lib": return await renderLib(r.uuid, r.query);
            case "libraries":
            default: return await renderLibraries();
        }
    } catch (e) {
        if (e instanceof UnauthorizedError) return; // すでに #/pair へ遷移済み
        if (e instanceof NetworkError) {
            render("StackNest", el("div", { class: "empty" }, "読み込めませんでした。"));
            toast("サーバに接続できません", { actionLabel: "再試行", onAction: () => route() });
            return;
        }
        render("StackNest", el("div", { class: "empty" }, "エラーが発生しました。"));
        toast(e.message || "エラーが発生しました", { actionLabel: "再試行", onAction: () => route() });
    }
}

// ---- ペアリング画面 ---------------------------------------------------------

function renderPair() {
    const form = el("form", { class: "pair-form" }, [
        el("p", { class: "pair-lead", text: "Mac の「設定 › 共有」に表示されたトークンを入力してください。" }),
        el("p", { class: "pair-hint", text: "iPhone のカメラで QR コードを読み取ると、ここは自動で入力されます。" }),
        el("input", {
            type: "text", id: "token-input", class: "pair-input",
            placeholder: "トークン", autocomplete: "off",
            autocapitalize: "off", autocorrect: "off", spellcheck: "false",
        }),
        el("button", { type: "submit", class: "btn-primary", text: "接続" }),
    ]);
    form.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const value = document.getElementById("token-input").value.trim();
        if (!value) { toast("トークンを入力してください"); return; }
        saveDeviceToken(value);
        // 到達性 + トークン妥当性を /libraries で確認（401 なら api 側でクリアされる）。
        try {
            await listLibraries();
            location.hash = "#/libraries";
        } catch (e) {
            if (e instanceof UnauthorizedError) {
                toast("トークンが正しくありません");
            } else if (e instanceof NetworkError) {
                toast("サーバに接続できません", { actionLabel: "再試行", onAction: () => form.requestSubmit() });
            } else {
                toast(e.message || "接続に失敗しました");
            }
        }
    });
    render("ペアリング", form);
}

// ---- ライブラリ一覧画面 -----------------------------------------------------

async function renderLibraries() {
    const libraries = await listLibraries();
    if (!Array.isArray(libraries) || libraries.length === 0) {
        render("ライブラリ", el("div", { class: "empty" },
            "Mac 側で「リモート共有を許可」したライブラリがここに表示されます。"));
        return;
    }
    const list = el("div", { class: "card-list" });
    for (const lib of libraries) {
        const card = el("button", {
            class: "card", type: "button",
            onClick: () => { location.hash = `#/lib/${encodeURIComponent(lib.id)}`; },
        }, [
            el("div", { class: "card-title" }, [
                lib.locked ? el("span", { class: "lock", title: "ロック中", text: "🔒" }) : null,
                el("span", { text: lib.name || "(無題)" }),
            ]),
            el("div", { class: "card-sub", text: `${lib.bookCount ?? 0} 冊` }),
        ]);
        list.append(card);
    }
    render("ライブラリ", list);
}

// ---- ライブラリ内（books ブラウズ + ロック庫の unlock フロー） ----------------

/// books 画面へ渡す DOM/描画ヘルパ束。
/// onLibraryUnshared: books 取得が 404（配信停止）になったときのフォールバック。
const booksDeps = { el, render, toast, route, appEl, onLibraryUnshared: handleLibraryUnshared };

/// reader 画面へ渡す DOM/描画ヘルパ束（booksDeps と同型）。
const readerDeps = { el, render, toast, appEl, onLibraryUnshared: handleLibraryUnshared, cancelActiveTransition };

async function renderLib(uuid, query) {
    // 画面そのものへの新規エントリ（フィルタ/ページ/ソート変更ではなく画面遷移）のときだけ、
    // データ到着前に最終レイアウト準拠のスケルトンを即時表示する（G17 Pack B）。
    // 同一画面内の再描画（route() の再呼び出し）では表示しない（毎回ちらつくのを避ける）。
    if (isFreshEntry(screenKeyFor({ name: "lib", uuid }))) {
        render("ライブラリ", buildBooksSkeleton({ el }), { showBack: true });
    }
    // ロック庫はトークン未保持だと books 取得が 403 になる。先に軽く叩いて判定する。
    const res = await api(`/libraries/${encodeURIComponent(uuid)}/books?per=1`, { libraryUUID: uuid });
    if (res.status === 403) {
        return promptUnlock(uuid);
    }
    // 404 = このライブラリの配信が（閲覧中に）OFF にされた。一覧へフォールバックする。
    if (res.status === 404) {
        return handleLibraryUnshared();
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return renderBooks(uuid, query, booksDeps);
}

/// 閲覧中のライブラリが配信停止されたとき（books 取得 404）の共通フォールバック。
/// トーストで通知し、ライブラリ一覧（配信中のみ表示）へ戻す。
function handleLibraryUnshared() {
    toast("このライブラリの共有が停止されました");
    location.hash = "#/libraries";
}

/// ロック庫のパスワード入力モーダル → unlock。
function promptUnlock(uuid) {
    const overlay = el("div", { class: "modal-overlay" });
    const errorLine = el("p", { class: "modal-error", hidden: true });
    const form = el("form", { class: "modal" }, [
        el("h2", { class: "modal-title", text: "ロックされたライブラリ" }),
        el("p", { class: "modal-lead", text: "このライブラリのパスワードを入力してください。" }),
        el("input", {
            type: "password", id: "lib-password", class: "pair-input",
            placeholder: "パスワード", autocomplete: "off",
        }),
        errorLine,
        el("div", { class: "modal-actions" }, [
            el("button", { type: "button", class: "btn-secondary", text: "戻る",
                onClick: () => { overlay.remove(); location.hash = "#/libraries"; } }),
            el("button", { type: "submit", class: "btn-primary", text: "解錠" }),
        ]),
    ]);
    form.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        errorLine.hidden = true;
        const pw = document.getElementById("lib-password").value;
        if (!pw) { errorLine.textContent = "パスワードを入力してください"; errorLine.hidden = false; return; }
        try {
            const ok = await unlockLibrary(uuid, pw);
            if (ok) {
                overlay.remove();
                route(); // 同じ #/lib/<uuid> を再評価（今度は books 取得が通る）
            } else {
                errorLine.textContent = "パスワードが違います";
                errorLine.hidden = false;
            }
        } catch (e) {
            if (e instanceof NetworkError) {
                errorLine.textContent = "サーバに接続できません";
            } else if (!(e instanceof UnauthorizedError)) {
                errorLine.textContent = e.message || "解錠に失敗しました";
            }
            errorLine.hidden = false;
        }
    });
    overlay.append(form);
    render("ライブラリ", el("div", { class: "placeholder" }), { showBack: true });
    appEl().append(overlay);
    setTimeout(() => { const i = document.getElementById("lib-password"); if (i) i.focus(); }, 0);
}

// ---- 起動: hash の #token= を取り込みペアリング → ルーティング開始 -------------

function consumePairingToken() {
    const m = location.hash.match(/[#&]token=([^&]+)/);
    if (m) {
        const token = decodeURIComponent(m[1]);
        if (token) saveDeviceToken(token);
        // トークンを URL から除去（履歴に残さない）。
        history.replaceState(null, "", location.pathname + location.search + "#/libraries");
    }
}

// ---- G21 #1: スクロールバー幅の実測 ------------------------------------------
/// `50vw` は縦スクロールバー幅を含み `50%`（包含ブロック基準）は含まないため、
/// スクロールバーが常時表示の環境では full-bleed 要素が左右にはみ出して横スクロールが出る。
/// CSS だけの定番手 `calc(100vw - 100%)` は**使えない**（カスタムプロパティは使用箇所で
/// 展開されるため `100%` が :root ではなく対象要素の包含ブロックに解決され、引きすぎる。
/// 実測で帯が全幅でなくなることを確認済み）。ここで px 実測して CSS 変数に入れる。
export function scrollbarWidthPx(win, docEl) {
    const w = Number(win?.innerWidth) || 0;
    const c = Number(docEl?.clientWidth) || 0;
    const diff = w - c;
    // 0 未満、または明らかに異常（スクロールバーとしてありえない幅）は 0 に倒して従来挙動にする。
    if (!Number.isFinite(diff) || diff <= 0 || diff > 64) return 0;
    return diff;
}

function applyScrollbarWidth() {
    const px = scrollbarWidthPx(window, document.documentElement);
    document.documentElement.style.setProperty("--sbw", px + "px");
}

function init() {
    applyScrollbarWidth();
    let sbwRAF = 0;
    window.addEventListener("resize", () => {
        if (sbwRAF) return;                       // rAF 1 フレームに間引く
        sbwRAF = requestAnimationFrame(() => { sbwRAF = 0; applyScrollbarWidth(); });
    });
    backBtn().addEventListener("click", () => {
        const r = parseRoute();
        if (r.name === "read") location.hash = resolveBackHash(r.uuid, r.query);
        else if (r.name === "lib") location.hash = "#/libraries";
        else location.hash = "#/libraries";
    });
    window.addEventListener("hashchange", route);
    // 幅が iPhone↔iPad/PC の境界（767px）を跨いだら再描画する。
    // column モードの stepper（狭幅）↔横並び（広幅）を live に切り替えるため。
    // 跨いだときだけ route() を呼ぶ（毎リサイズでの再描画＝入力 focus 喪失を避ける）。
    let lastNarrow = window.matchMedia("(max-width:767px)").matches;
    let resizeTimer = null;
    window.addEventListener("resize", () => {
        if (resizeTimer) clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => {
            const narrow = window.matchMedia("(max-width:767px)").matches;
            if (narrow === lastNarrow) return;
            lastNarrow = narrow;
            const r = parseRoute();
            if (r.name === "lib") route();
        }, 150);
    });
    consumePairingToken();
    if (!location.hash || location.hash === "#" || location.hash === "#/") {
        location.hash = hasDeviceToken() ? "#/libraries" : "#/pair";
    } else {
        route();
    }
}

// `typeof document` ガード: Node の `node --test` から本ファイルを import して
// `scrollbarWidthPx` のような純関数だけを単体テストできるようにするため
// （DOM が無い環境でモジュール評価時にこの副作用行が即座に throw するのを防ぐ）。
// ブラウザでは document は必ず定義されているため実際の起動挙動は変わらない。
if (typeof document !== "undefined") {
    document.addEventListener("DOMContentLoaded", init);
}
