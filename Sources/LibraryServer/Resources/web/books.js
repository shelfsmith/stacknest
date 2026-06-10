// SPDX-License-Identifier: MIT
// StackNest Web — books ブラウズ（list/grid・ページ切替・検索・ソート・表紙・詳細モーダル）。
// 状態は URL（#/lib/<uuid>?page=&q=&sort=）に反映し、表示モード/per/sort は localStorage に記憶する。

import { api, apiJSON } from "./api.js";

// ---- localStorage キー（端末ごとの表示設定） --------------------------------
const VIEW_KEY = "stacknest.books.view";   // "list" | "grid"
const PER_KEY = "stacknest.books.per";     // 50 | 100 | 200
const SORT_KEY = "stacknest.books.sort";   // title | series | dateAdded | lastRead

const SORT_OPTIONS = [
    { value: "title", label: "タイトル" },
    { value: "series", label: "シリーズ" },
    { value: "dateAdded", label: "追加日" },
    { value: "lastRead", label: "最終読書日" },
];
const SORT_VALUES = new Set(SORT_OPTIONS.map((o) => o.value));
const PER_OPTIONS = [50, 100, 200];

function getView() {
    const v = localStorage.getItem(VIEW_KEY);
    return v === "grid" ? "grid" : "list";
}
function setView(v) { localStorage.setItem(VIEW_KEY, v === "grid" ? "grid" : "list"); }

function getPer() {
    const n = parseInt(localStorage.getItem(PER_KEY) || "", 10);
    return PER_OPTIONS.includes(n) ? n : 100;
}
function setPer(n) { if (PER_OPTIONS.includes(n)) localStorage.setItem(PER_KEY, String(n)); }

function getSort() {
    const s = localStorage.getItem(SORT_KEY);
    return SORT_VALUES.has(s) ? s : "title";
}
function setSort(s) { if (SORT_VALUES.has(s)) localStorage.setItem(SORT_KEY, s); }

// ---- 1 件分のメタ表示用ヘルパ -----------------------------------------------

/// シリーズ + 巻数（巻は整数なら整数表示・小数は小数のまま）。シリーズ無しは空文字。
/// 巻数の表示文字列。整数は小数点なし・小数はそのまま（例 1 → "1", 1.5 → "1.5"）。
/// 値が無ければ null。
function volumeLabel(volume) {
    if (volume === null || volume === undefined) return null;
    return String(Number(volume));
}

function seriesLabel(book) {
    if (!book.series) return "";
    const vol = volumeLabel(book.volume);
    return vol === null ? book.series : `${book.series} 第${vol}巻`;
}

/// 進行状況「lastPage+1 / pages」。lastPage が null なら null（非表示）。
function progressLabel(book) {
    if (book.lastPage === null || book.lastPage === undefined) return null;
    if (book.pages === null || book.pages === undefined) return null;
    return `${book.lastPage + 1} / ${book.pages}`;
}

/// 表紙 URL。coverVersion が無ければ null（プレースホルダ表示）。
function coverURL(uuid, book, maxw = 320) {
    if (!book.coverVersion) return null;
    // ?v= が immutable キャッシュのキー。乱数は付けない（同じ v は再取得されない）。
    return `/api/v1/libraries/${encodeURIComponent(uuid)}/books/${book.id}/cover`
        + `?maxw=${maxw}&v=${encodeURIComponent(book.coverVersion)}`;
}

// ---- books 画面本体 ---------------------------------------------------------

/// books 画面を描画する。
/// deps: { el, render, toast, route } — app.js から DOM/描画ヘルパを受け取る。
/// query: parseRoute() の query（page/q/sort）。
export async function renderBooks(uuid, query, deps) {
    const { el, render } = deps;

    // URL の query を最優先、無ければ localStorage の記憶を使う。
    const page = Math.max(1, parseInt(query.page || "1", 10) || 1);
    const q = query.q || "";
    const sort = SORT_VALUES.has(query.sort) ? query.sort : getSort();
    const per = getPer();
    const view = getView();
    // sort は記憶に同期（URL で来た sort を次回既定にする）。
    setSort(sort);

    const data = await apiJSON(
        `/libraries/${encodeURIComponent(uuid)}/books`
        + `?q=${encodeURIComponent(q)}&sort=${encodeURIComponent(sort)}`
        + `&page=${page}&per=${per}`,
        { libraryUUID: uuid },
    );
    const items = Array.isArray(data.items) ? data.items : [];
    const total = data.total ?? 0;
    const perPage = data.perPage ?? per;
    const totalPages = Math.max(1, Math.ceil(total / Math.max(1, perPage)));

    // URL が範囲外ページを指していたら最終ページへ寄せる（リロード耐性）。
    if (page > totalPages && total > 0) {
        navigate(uuid, { page: totalPages, q, sort });
        return;
    }

    const root = el("div", { class: "books-screen" });

    // --- ツールバー（検索・ソート・表示切替） ---
    const search = el("input", {
        type: "search", class: "books-search", placeholder: "タイトル・シリーズ・著者で検索",
        value: q, autocomplete: "off", autocapitalize: "off",
        autocorrect: "off", spellcheck: "false", "aria-label": "検索",
    });
    // 300ms デバウンス。検索でページを 1 にリセット。
    let searchTimer = null;
    search.addEventListener("input", () => {
        if (searchTimer) clearTimeout(searchTimer);
        searchTimer = setTimeout(() => {
            navigate(uuid, { page: 1, q: search.value, sort });
        }, 300);
    });

    const sortSelect = el("select", { class: "books-sort", "aria-label": "並び替え" },
        SORT_OPTIONS.map((o) =>
            el("option", { value: o.value, selected: o.value === sort, text: o.label })));
    sortSelect.addEventListener("change", () => {
        const s = sortSelect.value;
        setSort(s);
        navigate(uuid, { page: 1, q, sort: s });
    });

    const viewBtn = el("button", {
        type: "button", class: "books-viewtoggle",
        "aria-label": view === "grid" ? "リスト表示に切替" : "グリッド表示に切替",
        title: view === "grid" ? "リスト表示" : "グリッド表示",
        text: view === "grid" ? "☰" : "▦",
    });
    viewBtn.addEventListener("click", () => {
        setView(view === "grid" ? "list" : "grid");
        // 同じ URL で再描画（hashchange は起きないので明示的に再評価）。
        deps.route();
    });

    root.append(el("div", { class: "books-toolbar" }, [
        search,
        el("div", { class: "books-toolbar-row" }, [sortSelect, viewBtn]),
    ]));

    // --- 件数 + ページャ（上） ---
    root.append(pager(uuid, { page, totalPages, total, perPage, q, sort, deps }));

    // --- 本体（list / grid） ---
    if (items.length === 0) {
        root.append(el("div", { class: "empty" },
            q ? "該当する本がありません。" : "このライブラリには本がありません。"));
    } else if (view === "grid") {
        root.append(gridView(uuid, items, deps));
    } else {
        root.append(listView(uuid, items, deps));
    }

    // --- ページャ（下） ---
    if (items.length > 0) {
        root.append(pager(uuid, { page, totalPages, total, perPage, q, sort, deps }));
    }

    render("ライブラリ", root, { showBack: true });
}

// ---- list 表示 --------------------------------------------------------------

function listView(uuid, items, deps) {
    const { el } = deps;
    const list = el("div", { class: "book-list" });
    for (const book of items) {
        const meta = [];
        const sl = seriesLabel(book);
        if (sl) meta.push(el("span", { class: "book-series" }, [
            el("button", {
                type: "button", class: "series-link", text: book.series,
                "aria-label": `シリーズ「${book.series}」で絞り込み`,
                onClick: (ev) => {
                    ev.stopPropagation();
                    seriesDrilldown(uuid, book.series, deps);
                },
            }),
            volumeLabel(book.volume) !== null
                ? el("span", { text: ` 第${volumeLabel(book.volume)}巻` })
                : null,
        ]));
        const pl = progressLabel(book);
        if (pl) meta.push(el("span", { class: "book-progress", text: pl }));

        const right = [];
        if (book.unseen) right.push(el("span", { class: "unseen-dot", title: "未読", "aria-label": "未読" }));
        if (book.rating > 0) right.push(el("span", { class: "book-rating", "aria-label": `星${book.rating}`, text: "★".repeat(book.rating) }));

        const row = el("button", {
            type: "button", class: "book-row",
            onClick: () => openDetail(uuid, book, deps),
        }, [
            el("div", { class: "book-row-main" }, [
                el("div", { class: "book-title", text: book.title || "(無題)" }),
                meta.length ? el("div", { class: "book-meta" }, meta) : null,
            ]),
            right.length ? el("div", { class: "book-row-side" }, right) : null,
        ]);
        list.append(row);
    }
    return list;
}

// ---- grid 表示 --------------------------------------------------------------

function gridView(uuid, items, deps) {
    const { el } = deps;
    const grid = el("div", { class: "book-grid" });
    for (const book of items) {
        const url = coverURL(uuid, book, 320);
        let cover;
        if (url) {
            cover = el("img", {
                class: "grid-cover", src: url, loading: "lazy", decoding: "async",
                alt: book.title || "", draggable: "false",
            });
        } else {
            // 表紙なし: タイトル文字のプレースホルダ枠。
            cover = el("div", { class: "grid-cover grid-cover-empty" },
                [el("span", { class: "grid-cover-text", text: book.title || "(無題)" })]);
        }
        const badges = [];
        if (book.unseen) badges.push(el("span", { class: "grid-unseen", "aria-label": "未読" }));
        const tile = el("button", {
            type: "button", class: "book-tile",
            onClick: () => openDetail(uuid, book, deps),
        }, [
            el("div", { class: "grid-cover-wrap" }, [cover, ...badges]),
            el("div", { class: "grid-title", text: book.title || "(無題)" }),
        ]);
        grid.append(tile);
    }
    return grid;
}

// ---- ページャ ---------------------------------------------------------------

function pager(uuid, { page, totalPages, total, perPage, q, sort, deps }) {
    const { el } = deps;
    const prev = el("button", {
        type: "button", class: "pager-btn", text: "‹ 前",
        disabled: page <= 1,
        onClick: () => navigate(uuid, { page: page - 1, q, sort }),
    });
    const next = el("button", {
        type: "button", class: "pager-btn", text: "次 ›",
        disabled: page >= totalPages,
        onClick: () => navigate(uuid, { page: page + 1, q, sort }),
    });

    const perSelect = el("select", { class: "pager-per", "aria-label": "1ページの件数" },
        PER_OPTIONS.map((n) =>
            el("option", { value: n, selected: n === perPage, text: `${n}件` })));
    perSelect.addEventListener("change", () => {
        const n = parseInt(perSelect.value, 10);
        setPer(n);
        navigate(uuid, { page: 1, q, sort });
    });

    return el("div", { class: "pager" }, [
        prev,
        el("span", { class: "pager-info", text: `${page} / 全${totalPages}（${total}冊）` }),
        next,
        perSelect,
    ]);
}

// ---- 詳細モーダル -----------------------------------------------------------

function openDetail(uuid, book, deps) {
    const { el, appEl } = deps;
    const overlay = el("div", { class: "modal-overlay" });
    // 背景タップ / 閉じるボタン / hashchange（戻りスワイプ等）いずれでも overlay を確実に除去する。
    function onHashChange() { close(); }
    function close() {
        overlay.remove();
        window.removeEventListener("hashchange", onHashChange);
    }
    window.addEventListener("hashchange", onHashChange);
    overlay.addEventListener("click", (ev) => { if (ev.target === overlay) close(); });

    const url = coverURL(uuid, book, 320);
    const coverEl = url
        ? el("img", { class: "detail-cover", src: url, alt: book.title || "", decoding: "async" })
        : el("div", { class: "detail-cover detail-cover-empty" },
            [el("span", { class: "grid-cover-text", text: book.title || "(無題)" })]);

    const rows = [];
    const addRow = (label, value) => {
        if (value === null || value === undefined || value === "") return;
        rows.push(el("div", { class: "detail-row" }, [
            el("span", { class: "detail-label", text: label }),
            el("span", { class: "detail-value", text: String(value) }),
        ]));
    };
    if (book.author) addRow("著者", book.author);
    if (book.series) {
        rows.push(el("div", { class: "detail-row" }, [
            el("span", { class: "detail-label", text: "シリーズ" }),
            el("button", {
                type: "button", class: "series-link", text: seriesLabel(book) || book.series,
                onClick: () => { close(); seriesDrilldown(uuid, book.series, deps); },
            }),
        ]));
    }
    if (book.rating > 0) addRow("評価", "★".repeat(book.rating));
    const pl = progressLabel(book);
    if (pl) addRow("進行", pl);
    else if (book.pages) addRow("ページ数", book.pages);
    if (book.dateAdded) addRow("追加日", formatDate(book.dateAdded));
    if (book.lastReadAt) addRow("最終読書", formatDate(book.lastReadAt));

    const modal = el("div", { class: "modal detail-modal", role: "dialog", "aria-label": "本の詳細" }, [
        el("div", { class: "detail-header" }, [
            coverEl,
            el("div", { class: "detail-headinfo" }, [
                el("h2", { class: "detail-title", text: book.title || "(無題)" }),
                book.author ? el("p", { class: "detail-author", text: book.author }) : null,
            ]),
        ]),
        rows.length ? el("div", { class: "detail-rows" }, rows) : null,
        el("p", { class: "detail-note", text: "リーダー（本を開く機能）は次のフェーズで対応します。" }),
        el("div", { class: "modal-actions" }, [
            el("button", { type: "button", class: "btn-primary", text: "閉じる", onClick: close }),
        ]),
    ]);
    overlay.append(modal);
    // #app 配下に置く（modal-overlay は position:fixed なのでビューポート基準のまま）。
    // route() 遷移時に既存の clear 機構でも除去され、上の hashchange ハンドラと二重に安全。
    appEl().append(overlay);
}

/// ISO8601 日付文字列 → ローカル日付（YYYY/MM/DD）。失敗時は元文字列。
function formatDate(s) {
    const d = new Date(s);
    if (isNaN(d.getTime())) return s;
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}/${m}/${day}`;
}

// ---- シリーズドリルダウン（contains 近似 + sort=series） ----------------------
// 注: 厳密な series= フィルタ API は 4.4 候補。現状は検索ボックスにシリーズ名を入れ、
//     sort=series に切替える近似で代替する（contains 検索なので部分一致を含みうる）。
function seriesDrilldown(uuid, series, deps) {
    setSort("series");
    navigate(uuid, { page: 1, q: series || "", sort: "series" });
}

// ---- URL 遷移（状態を hash に反映） ------------------------------------------

/// books 画面の状態を hash に書き込んで遷移する。
/// 空の q は URL に載せない（短く保つ）。
export function buildBooksHash(uuid, { page = 1, q = "", sort = "title" } = {}) {
    const params = [];
    if (page && page !== 1) params.push(`page=${page}`);
    if (q) params.push(`q=${encodeURIComponent(q)}`);
    if (sort && sort !== "title") params.push(`sort=${encodeURIComponent(sort)}`);
    const qs = params.length ? `?${params.join("&")}` : "";
    return `#/lib/${encodeURIComponent(uuid)}${qs}`;
}

function navigate(uuid, state) {
    location.hash = buildBooksHash(uuid, state);
}
