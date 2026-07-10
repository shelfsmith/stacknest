// SPDX-License-Identifier: MIT
// StackNest Web クライアント — SPA・hash ルーティング。
// Task 6: 基盤 + ペアリング + ライブラリ一覧（books 画面は Task 7。今は「準備中」）。

import {
    api, apiJSON, hasDeviceToken, saveDeviceToken, clearDeviceToken,
    listLibraries, unlockLibrary, UnauthorizedError, NetworkError,
} from "./api.js";
import { renderBooks } from "./books.js";
import { renderReader } from "./reader.js";
import { stopLiveSync } from "./livesync.js";

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

/// 画面差し替え。タイトルと戻るボタンの表示も整える。
function render(title, content, { showBack = false } = {}) {
    titleEl().textContent = title;
    backBtn().hidden = !showBack;
    const main = appEl();
    clear(main);
    main.append(content);
    main.scrollTop = 0;
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
const readerDeps = { el, render, toast, appEl, onLibraryUnshared: handleLibraryUnshared };

async function renderLib(uuid, query) {
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

function init() {
    backBtn().addEventListener("click", () => {
        const r = parseRoute();
        if (r.name === "read") location.hash = `#/lib/${encodeURIComponent(r.uuid)}`;
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

document.addEventListener("DOMContentLoaded", init);
