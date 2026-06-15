// SPDX-License-Identifier: MIT
// StackNest Web — books ブラウズ（list/grid・ページ切替・検索・ソート・表紙・詳細モーダル）。
// 状態は URL（#/lib/<uuid>?page=&q=&sort=）に反映し、表示モード/per/sort は localStorage に記憶する。

import { api, apiJSON, deviceToken, libToken, browseParam, fetchFacet } from "./api.js";

// ---- localStorage キー（端末ごとの表示設定） --------------------------------
const VIEW_KEY = "stacknest.books.view";   // "list" | "grid" | "column"
const PER_KEY = "stacknest.books.per";     // 50 | 100 | 200
const SORT_KEY = "stacknest.books.sort";   // title | series | dateAdded | lastRead
const ORDER_KEY = "stacknest.books.order"; // asc | desc
const SCROLLMODE_KEY = "stacknest.books.scrollmode"; // "paged" | "infinite"

const SORT_OPTIONS = [
    { value: "title", label: "タイトル" },
    { value: "series", label: "シリーズ" },
    { value: "dateAdded", label: "追加日" },
    { value: "lastRead", label: "最終読書日" },
];
const SORT_VALUES = new Set(SORT_OPTIONS.map((o) => o.value));
const PER_OPTIONS = [50, 100, 200];
const ORDER_VALUES = new Set(["asc", "desc"]);
const SCROLLMODE_VALUES = new Set(["paged", "infinite"]);
// ソートキーごとの自然な既定方向（サーバの BookSortKey.defaultOrder と一致させる）。
const DEFAULT_ORDER = { title: "asc", series: "asc", dateAdded: "desc", lastRead: "desc" };

const VIEW_VALUES = new Set(["list", "grid", "column"]);
function getView() {
    const v = localStorage.getItem(VIEW_KEY);
    return VIEW_VALUES.has(v) ? v : "list";
}
function setView(v) { localStorage.setItem(VIEW_KEY, VIEW_VALUES.has(v) ? v : "list"); }

/// iPhone 幅（狭幅）判定。column モードのフルスクリーン stepper の出し分けに使う。
function isNarrow() { return window.matchMedia("(max-width:767px)").matches; }

// ---- browse（ファセット ドリルダウン）定義 ----------------------------------
// レベル順: ジャンル → 作者 → シリーズ。SQL 列名 / 日本語ラベル / URL クエリ名。
const BROWSE_LEVELS = [
    { column: "genre", label: "ジャンル", param: "g" },
    { column: "author", label: "作者", param: "a" },
    { column: "series", label: "シリーズ", param: "s" },
];

/// query（parseRoute の query）から各レベルの選択値を読み出す。
/// 返り値は { genre, author, series }（未選択は ""）。
function browseSelection(query) {
    const sel = {};
    for (const lv of BROWSE_LEVELS) sel[lv.column] = query[lv.param] || "";
    return sel;
}

/// 選択値 { genre, author, series } → browse 制約配列 [{column,value},...]。
/// 値のあるレベルだけを BROWSE_LEVELS の順で含める。
function browseConstraints(sel) {
    const out = [];
    for (const lv of BROWSE_LEVELS) {
        const v = sel[lv.column];
        if (v) out.push({ column: lv.column, value: v });
    }
    return out;
}

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

function getOrder(sort) {
    const o = localStorage.getItem(ORDER_KEY);
    return ORDER_VALUES.has(o) ? o : (DEFAULT_ORDER[sort] || "asc");
}
function setOrder(o) { if (ORDER_VALUES.has(o)) localStorage.setItem(ORDER_KEY, o); }

/// スクロール表示モード（ページ表示 / 無限スクロール）。既定は "paged"。
function getScrollMode() {
    const v = localStorage.getItem(SCROLLMODE_KEY);
    return SCROLLMODE_VALUES.has(v) ? v : "paged";
}
function setScrollMode(v) { if (SCROLLMODE_VALUES.has(v)) localStorage.setItem(SCROLLMODE_KEY, v); }

// 無限スクロールの IntersectionObserver は描画ごとに 1 つだけ存在させる。
// 次の描画（フィルタ変更等）の冒頭で前回分を必ず disconnect してリークを防ぐ。
let infObserver = null;
function resetInfiniteScroll() {
    if (infObserver) { infObserver.disconnect(); infObserver = null; }
}

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
/// `<img>` はカスタムヘッダを送れないため、認証は `?token=` クエリで渡す
/// （ロック庫はライブラリトークンも `?lt=` で付与）。token は再生成可能・LAN 用。
// ---- SVG 生成ヘルパ（el は HTML 名前空間専用なので SVG 用に分ける） ----------
// XSS 回避のため innerHTML は使わず、SVG 要素も DOM API（createElementNS）で組む。
const SVG_NS = "http://www.w3.org/2000/svg";

/// SVG 要素を生成する。attrs は属性、children は SVG 子要素配列。
function svgEl(tag, attrs = {}, children = []) {
    const node = document.createElementNS(SVG_NS, tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (v === false || v === null || v === undefined) continue;
        node.setAttribute(k, String(v));
    }
    for (const c of [].concat(children)) {
        if (c === null || c === undefined || c === false) continue;
        node.append(c);
    }
    return node;
}

/// grid アイコン（SF Symbols `square.grid.2x2` 相当）: 2×2 の角丸四角 4 個。
function gridIconSVG() {
    const r = (x, y) => svgEl("rect", {
        x, y, width: 7, height: 7, rx: 1.6, ry: 1.6,
        fill: "none", stroke: "currentColor", "stroke-width": 1.6,
    });
    return svgEl("svg", {
        class: "tb-icon", viewBox: "0 0 20 20",
        "aria-hidden": "true", focusable: "false",
    }, [r(2, 2), r(11, 2), r(2, 11), r(11, 11)]);
}

/// list アイコン（SF Symbols `list.bullet` 相当）: 行頭の点 + 横線 3 行。
function listIconSVG() {
    const kids = [];
    const ys = [4, 10, 16];
    for (const y of ys) {
        kids.push(svgEl("circle", { cx: 3.5, cy: y, r: 1.4, fill: "currentColor" }));
        kids.push(svgEl("line", {
            x1: 7.5, y1: y, x2: 18, y2: y,
            stroke: "currentColor", "stroke-width": 1.6, "stroke-linecap": "round",
        }));
    }
    return svgEl("svg", {
        class: "tb-icon", viewBox: "0 0 20 20",
        "aria-hidden": "true", focusable: "false",
    }, kids);
}

/// カラム アイコン（Finder カラム表示相当）: 角丸四角を縦 3 列に分割。
function columnIconSVG() {
    const outer = svgEl("rect", {
        x: 2, y: 3, width: 16, height: 14, rx: 2, ry: 2,
        fill: "none", stroke: "currentColor", "stroke-width": 1.6,
    });
    const mk = (x) => svgEl("line", {
        x1: x, y1: 3, x2: x, y2: 17, stroke: "currentColor", "stroke-width": 1.6,
    });
    return svgEl("svg", {
        class: "tb-icon", viewBox: "0 0 20 20",
        "aria-hidden": "true", focusable: "false",
    }, [outer, mk(7.3), mk(12.7)]);
}

function coverURL(uuid, book, maxw = 320) {
    if (!book.coverVersion) return null;
    // ?v= が immutable キャッシュのキー。乱数は付けない（同じ v は再取得されない）。
    let url = `/api/v1/libraries/${encodeURIComponent(uuid)}/books/${book.id}/cover`
        + `?maxw=${maxw}&v=${encodeURIComponent(book.coverVersion)}`
        + `&token=${encodeURIComponent(deviceToken() || "")}`;
    const lt = libToken(uuid);
    if (lt) url += `&lt=${encodeURIComponent(lt)}`;
    return url;
}

// ---- books 取得（ページ単位） ----------------------------------------------

/// /books を 1 ページ分取得する（無限スクロールの次ページ追記でも再利用）。
/// 返り値は apiJSON の生 JSON（items/total/perPage 等）。
function fetchBooksPage(uuid, { q, sort, order, page, per, browse }) {
    return apiJSON(
        `/libraries/${encodeURIComponent(uuid)}/books`
        + `?q=${encodeURIComponent(q)}&sort=${encodeURIComponent(sort)}`
        + `&order=${encodeURIComponent(order)}`
        + `&page=${page}&per=${per}`
        + browseParam(browse),
        { libraryUUID: uuid },
    );
}

/// 取得済み items を既存コンテナ（.book-list / .book-grid）へ追記する。
/// view に応じて listView/gridView でノードを組み、その子要素を container へ移す
/// （ビルダを丸ごと再利用するため、行/カードの構築ロジックを二重持ちしない）。
function appendItems(container, uuid, items, view, deps) {
    const built = view === "grid" ? gridView(uuid, items, deps) : listView(uuid, items, deps);
    while (built.firstChild) container.append(built.firstChild);
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
    const order = ORDER_VALUES.has(query.order) ? query.order : getOrder(sort);
    const per = getPer();
    const view = getView();
    const scrollMode = getScrollMode();
    // browse（ファセット ドリルダウン）選択。URL の g/a/s から読む。
    const sel = browseSelection(query);
    const currentBrowse = browseConstraints(sel);
    // sort/order は記憶に同期（URL で来た値を次回既定にする）。
    setSort(sort);
    setOrder(order);

    // 描画をやり直すので、前回の無限スクロール observer は必ず切る（リーク防止）。
    resetInfiniteScroll();

    let data;
    try {
        data = await fetchBooksPage(uuid, { q, sort, order, page, per, browse: currentBrowse });
    } catch (e) {
        // 404 = 閲覧中に Mac 側でこのライブラリの配信が OFF にされた。
        // （ページャ/検索/ソート操作の再取得でも起こりうる）一覧へフォールバックする。
        if (e && e.status === 404 && typeof deps.onLibraryUnshared === "function") {
            deps.onLibraryUnshared();
            return;
        }
        throw e;
    }
    const items = Array.isArray(data.items) ? data.items : [];
    const total = data.total ?? 0;
    const perPage = data.perPage ?? per;
    const totalPages = Math.max(1, Math.ceil(total / Math.max(1, perPage)));

    // 狭幅 column stepper の現在地（0=ジャンル/1=作者/2=シリーズ/3=結果）。
    const narrowColumn = view === "column" && isNarrow();
    let step = Math.max(0, Math.min(3, parseInt(query.step || "0", 10) || 0));

    // browse 選択を navigate に載せ直すための共通フィールド（g/a/s）。
    // 狭幅 column のときは step も維持（ページ送り・検索・ソートで現在地を保つ）。
    const selParams = { g: sel.genre, a: sel.author, s: sel.series };
    if (narrowColumn) selParams.step = step;

    // URL が範囲外ページを指していたら最終ページへ寄せる（リロード耐性）。
    if (page > totalPages && total > 0) {
        navigate(uuid, { page: totalPages, q, sort, order, ...selParams });
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
    // navigate() は DOM（検索 input 含む）を作り直すため、IME 変換中に発火すると
    // focus と未確定の変換が破棄され、日本語入力が確定前に中断される。
    // → compositionstart〜compositionend の間は発火させず、確定時に拾う。
    let searchTimer = null;
    let composing = false;
    const scheduleSearch = () => {
        if (searchTimer) clearTimeout(searchTimer);
        searchTimer = setTimeout(() => {
            navigate(uuid, { page: 1, q: search.value, sort, order, ...selParams });
        }, 300);
    };
    search.addEventListener("compositionstart", () => { composing = true; });
    search.addEventListener("compositionend", () => {
        composing = false;
        scheduleSearch();
    });
    search.addEventListener("input", (ev) => {
        // 変換中は無視。確定は compositionend で拾う。
        if (composing || ev.isComposing) return;
        scheduleSearch();
    });

    const sortSelect = el("select", { class: "books-sort", "aria-label": "並び替え" },
        SORT_OPTIONS.map((o) =>
            el("option", { value: o.value, selected: o.value === sort, text: o.label })));
    sortSelect.addEventListener("change", () => {
        const s = sortSelect.value;
        setSort(s);
        // キー変更時はそのキーの自然な既定方向に戻す（記憶も更新）。
        const o = DEFAULT_ORDER[s] || "asc";
        setOrder(o);
        navigate(uuid, { page: 1, q, sort: s, order: o, ...selParams });
    });

    // 昇順/降順トグル。現在方向を表示し、押すと反転する。
    const orderBtn = el("button", {
        type: "button", class: "books-ordertoggle",
        "aria-label": order === "asc" ? "降順に切替" : "昇順に切替",
        title: order === "asc" ? "昇順（押すと降順）" : "降順（押すと昇順）",
        text: order === "asc" ? "↑ 昇順" : "↓ 降順",
    });
    orderBtn.addEventListener("click", () => {
        const o = order === "asc" ? "desc" : "asc";
        setOrder(o);
        navigate(uuid, { page: 1, q, sort, order: o, ...selParams });
    });

    // 表示モード切替（リスト / グリッド / カラム）のセグメント コントロール。
    const makeSegBtn = (mode, label, icon) => {
        const btn = el("button", {
            type: "button",
            class: mode === view ? "seg-btn sel" : "seg-btn",
            "aria-pressed": mode === view ? "true" : "false",
            "aria-label": `${label}表示`,
            title: `${label}表示`,
        }, icon ? [icon] : [label]);
        btn.addEventListener("click", () => {
            if (mode === view) return;
            setView(mode);
            // 表示モードを切り替えたら browse（ファセット）選択と step を破棄して
            // page 1 から開始する（カラムのドリルダウンを list/grid に持ち越さない）。
            navigate(uuid, { page: 1, q, sort, order });
        });
        return btn;
    };
    const viewSeg = el("div", { class: "seg", role: "group", "aria-label": "表示モード" }, [
        makeSegBtn("grid", "グリッド", gridIconSVG()),
        makeSegBtn("list", "リスト", listIconSVG()),
        makeSegBtn("column", "カラム", columnIconSVG()),
    ]);

    // 件数セレクタ（50/100/200/無限）。無限スクロールのモード選択もここに統合する。
    // 現在値: 無限モードなら "infinite"、ページ表示なら現在の per（数値）。
    // ツールバー行に常設し、無限モードでも見えるようにする（戻れるように）。
    const perScrollSelect = el("select", { class: "pager-per books-perscroll", "aria-label": "表示件数 / スクロール" },
        [
            ...PER_OPTIONS.map((n) =>
                el("option", { value: String(n), selected: scrollMode !== "infinite" && n === per, text: `${n}件` })),
            el("option", { value: "infinite", selected: scrollMode === "infinite", text: "無限" }),
        ]);
    perScrollSelect.addEventListener("change", () => {
        const v = perScrollSelect.value;
        if (v === "infinite") {
            setScrollMode("infinite");
        } else {
            setScrollMode("paged");
            setPer(parseInt(v, 10));
        }
        // per/scrollMode は localStorage 記憶で URL に載らない。hashchange が起きない場合に
        // 備えて navigate（page 1 へ）＋ route() で確実に再評価・再描画する。
        navigate(uuid, { page: 1, q, sort, order, ...selParams });
        deps.route();
    });

    root.append(el("div", { class: "books-toolbar" }, [
        search,
        el("div", { class: "books-toolbar-row" }, [sortSelect, orderBtn, viewSeg, perScrollSelect]),
    ]));

    // --- 狭幅 column: フルスクリーン stepper（1 列ずつ → 結果） ---
    if (narrowColumn && step < 3) {
        // 値選択 → そのレベルを設定し step を 1 つ進めて navigate。
        const onPickNarrow = (columnIdx, value) => {
            const sp = selParamsWithLevel(sel, columnIdx, value);
            navigate(uuid, {
                page: 1, q, sort, order, ...sp, step: columnIdx + 1,
            });
        };
        root.append(renderStepperBar(uuid, { sel, step, q, sort, order, deps }));
        root.append(el("div", { class: "columns stepper" }, [
            buildFacetColumn(uuid, step, { sel, q, deps, onPick: onPickNarrow }),
        ]));
        render("ライブラリ", root, { showBack: true });
        return;
    }

    // --- カラム（ファセット）エリア ---
    if (narrowColumn) {
        // step === 3: 結果リスト（「‹ 戻る」で step 2 へ）。
        root.append(stepBackBar(uuid, { ...selParams, page: 1, q, sort, order, step: 2 }, deps));
    } else if (view === "column") {
        // wide（iPad/PC）: Task 3 の横並び 3 列。
        root.append(renderColumns(uuid, { sel, q, deps }));
    }

    // 無限スクロール時は本体（list/grid）を結果として扱い、ページャは出さない。
    const infinite = scrollMode === "infinite";

    // --- 件数 + ページャ（上）。無限スクロールでは件数だけ出す（ページ送りは隠す）。---
    const pagerStep = narrowColumn ? step : undefined;
    if (infinite) {
        root.append(el("div", { class: "pager pager-countonly" }, [
            el("span", { class: "pager-info", text: `全${total}冊` }),
        ]));
    } else {
        root.append(pager(uuid, { page, totalPages, total, perPage, q, sort, order, sel, step: pagerStep, deps }));
    }

    // --- 本体（list / grid / column）。column モードの結果はリスト表示。 ---
    // 結果コンテナの参照を保持（無限スクロールで次ページを追記する先）。
    let resultContainer = null;
    if (items.length === 0) {
        root.append(el("div", { class: "empty" },
            q ? "該当する本がありません。" : "このライブラリには本がありません。"));
    } else if (view === "grid") {
        resultContainer = gridView(uuid, items, deps);
        root.append(resultContainer);
    } else {
        resultContainer = listView(uuid, items, deps);
        root.append(resultContainer);
    }

    if (infinite && resultContainer) {
        // 無限スクロール: 末尾のセンチネルが見えたら次ページを取得して追記する。
        // loadedPage は描画済みの最終ページ（=今描いた page）から開始。
        setupInfiniteScroll(root, resultContainer, deps, {
            uuid, q, sort, order, per, browse: currentBrowse,
            view, loadedPage: page, totalPages,
        });
    } else if (items.length > 0) {
        // ページ表示: 下にもページャを置く。
        root.append(pager(uuid, { page, totalPages, total, perPage, q, sort, order, sel, step: pagerStep, deps }));
    }

    render("ライブラリ", root, { showBack: true });
}

// ---- 無限スクロール ---------------------------------------------------------

/// 結果コンテナへ次ページを順次追記する仕組みを設定する。
/// root: 画面ルート（センチネル/インジケータの設置先）。container: 追記先（list/grid）。
/// state: { uuid,q,sort,order,per,browse,view,loadedPage,totalPages }。
function setupInfiniteScroll(root, container, deps, state) {
    const { el } = deps;
    let { loadedPage } = state;
    const { totalPages } = state;
    let loading = false;

    // 末尾インジケータ + センチネル（observe 対象）。
    const status = el("div", { class: "inf-status" });
    const sentinel = el("div", { class: "inf-sentinel", "aria-hidden": "true" });
    root.append(status);
    root.append(sentinel);

    // 全ページ読み込み済みなら observer 不要。
    if (loadedPage >= totalPages) return;

    const loadNext = async () => {
        if (loading || loadedPage >= totalPages) return;
        loading = true;
        status.textContent = "読み込み中…";
        status.classList.remove("inf-error");
        try {
            const next = loadedPage + 1;
            const data = await fetchBooksPage(state.uuid, {
                q: state.q, sort: state.sort, order: state.order,
                page: next, per: state.per, browse: state.browse,
            });
            const newItems = Array.isArray(data.items) ? data.items : [];
            appendItems(container, state.uuid, newItems, state.view, deps);
            loadedPage = next;
            status.textContent = "";
            if (loadedPage >= totalPages) {
                resetInfiniteScroll();   // 完了。observe を止める。
            }
        } catch (e) {
            // エラー時は停止し、タップで再試行できるようにする。
            status.textContent = "読み込みに失敗しました。タップで再試行";
            status.classList.add("inf-error");
            status.onclick = () => { status.onclick = null; loadNext(); };
        } finally {
            loading = false;
        }
    };

    infObserver = new IntersectionObserver((entries) => {
        for (const entry of entries) {
            if (entry.isIntersecting) { loadNext(); break; }
        }
    }, { rootMargin: "400px 0px" });
    infObserver.observe(sentinel);
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

        // 4.2c: list 行にも小さな表紙サムネ（遅延読み込み・縮小・キャッシュ）。表紙なしはプレースホルダ。
        const thumbURL = coverURL(uuid, book, 120);
        const thumb = thumbURL
            ? el("img", { class: "book-row-thumb", src: thumbURL, loading: "lazy", decoding: "async", alt: "" })
            : el("div", { class: "book-row-thumb book-row-thumb-empty" });
        const row = el("button", {
            type: "button", class: "book-row",
            onClick: () => openDetail(uuid, book, deps),
        }, [
            thumb,
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

// ---- カラム（ファセット ドリルダウン）表示 ----------------------------------
// wide（iPad/PC）: ジャンル → 作者 → シリーズ の列を横並びで表示し、上位の選択が
// 下位の候補を絞り込む。各列の先頭は「すべて」（そのレベルの選択解除）。
// 値クリックでそのレベルを設定し下位をクリア → navigate(g/a/s) → route 再描画。
//
// 非同期: 各列の候補はサーバ取得。まずプレースホルダ枠を返し、fetch 完了後に中身を
// 差し込む（レンダリングはブロックしない）。連打時の競合は「最新 navigate が勝つ」で
// 吸収する（route 再描画で全体が作り直されるため）。

/// browse 選択 { genre, author, series } に対し、指定レベルより「厳密に上位」だけの
/// 制約配列を返す（その列の候補を絞るための upper constraints）。
function upperConstraintsFor(columnIdx, sel) {
    const out = [];
    for (let i = 0; i < columnIdx; i++) {
        const lv = BROWSE_LEVELS[i];
        const v = sel[lv.column];
        if (v) out.push({ column: lv.column, value: v });
    }
    return out;
}

/// レベル選択を更新した browse パラメータ（g/a/s）を作る。
/// 指定レベルに value を設定し、それより下位はすべてクリアする。
/// value が "" のときはそのレベルもクリア（=「すべて」）。
function selParamsWithLevel(sel, columnIdx, value) {
    const next = { genre: "", author: "", series: "" };
    for (let i = 0; i < columnIdx; i++) {
        const c = BROWSE_LEVELS[i].column;
        next[c] = sel[c] || "";
    }
    if (value) next[BROWSE_LEVELS[columnIdx].column] = value;
    return { g: next.genre, a: next.author, s: next.series };
}

/// 1 列分の DOM を構築する（Task 4 のフルスクリーン stepper でも再利用可能）。
/// columnIdx: BROWSE_LEVELS のインデックス。sel: 現在選択。q: 検索語。
/// onPick(value): 値選択時の遷移ハンドラ（""=すべて）。
/// 返り値はすぐ返る列要素。候補は非同期に fetch して差し込む。
function buildFacetColumn(uuid, columnIdx, { sel, q, deps, onPick }) {
    const { el } = deps;
    const lv = BROWSE_LEVELS[columnIdx];
    const selectedValue = sel[lv.column] || "";

    const listEl = el("div", { class: "col-list" });
    const countEl = el("span", { class: "col-count" });
    const header = el("div", { class: "col-h" }, [
        el("span", { class: "col-label", text: lv.label }),
        countEl,
    ]);

    // 先頭「すべて」項目。
    const allItem = el("button", {
        type: "button",
        class: selectedValue ? "col-item all" : "col-item all sel",
        onClick: () => onPick(columnIdx, ""),
    }, ["すべて"]);
    listEl.append(allItem);

    // ローディング プレースホルダ。
    const loading = el("div", { class: "col-loading", text: "…" });
    listEl.append(loading);

    const upper = upperConstraintsFor(columnIdx, sel);
    fetchFacet(uuid, lv.column, { browse: upper, q })
        .then((values) => {
            loading.remove();
            const arr = Array.isArray(values) ? values : [];
            countEl.textContent = String(arr.length);
            for (const value of arr) {
                if (value === null || value === undefined || value === "") continue;
                const isSel = value === selectedValue;
                listEl.append(el("button", {
                    type: "button",
                    class: isSel ? "col-item sel" : "col-item",
                    onClick: () => onPick(columnIdx, value),
                }, [String(value)]));
            }
        })
        .catch(() => {
            loading.textContent = "読み込み失敗";
        });

    return el("div", { class: "col" }, [header, listEl]);
}

/// wide のカラム エリア全体（横並び 3 列）を構築する。
function renderColumns(uuid, { sel, q, deps }) {
    const { el } = deps;
    // 値選択 → navigate（最新が勝つ）。レベル設定で下位をクリア、ページは 1 に戻す。
    // navigate で hash の g/a/s が変わる（=hashchange→route 再描画）。検索/ソートと同様、
    // 明示 route() は呼ばない（既に「すべて」を再選択した等で hash が変わらない場合は no-op）。
    const onPick = (columnIdx, value) => {
        const sp = selParamsWithLevel(sel, columnIdx, value);
        navigate(uuid, { page: 1, q, sort: getSort(), order: getOrder(getSort()), ...sp });
    };
    const cols = BROWSE_LEVELS.map((_lv, idx) =>
        buildFacetColumn(uuid, idx, { sel, q, deps, onPick }));
    return el("div", { class: "columns" }, cols);
}

// ---- 狭幅 column stepper（フルスクリーン 1 列ずつ） --------------------------
// iPhone 幅では 3 列を一度に出さず、ジャンル → 作者 → シリーズ → 結果 と 1 画面ずつ
// 進める。上部に「‹ 戻る」（step>0 で有効）とパンくず（各レベルの選択値 / すべて /
// 未到達ラベル）を置き、パンくずタップで任意のレベルへジャンプできる。

/// 「‹ 戻る」のみのバー（step→指定 step へ navigate）。step===3 の結果画面で使う。
function stepBackBar(uuid, navState, deps) {
    const { el } = deps;
    const back = el("button", {
        type: "button", class: "icon-btn step-back", text: "‹ 戻る",
        "aria-label": "前のステップに戻る",
        onClick: () => navigate(uuid, navState),
    });
    return el("div", { class: "stepper-bar" }, [back]);
}

/// stepper の上部バー（戻る + パンくず）。step は現在地（0..2）。
function renderStepperBar(uuid, { sel, step, q, sort, order, deps }) {
    const { el } = deps;
    const selParams = { g: sel.genre, a: sel.author, s: sel.series };

    // 戻る（step>0 のとき 1 つ前へ）。
    const back = step > 0
        ? el("button", {
            type: "button", class: "icon-btn step-back", text: "‹ 戻る",
            "aria-label": "前のステップに戻る",
            onClick: () => navigate(uuid, { page: 1, q, sort, order, ...selParams, step: step - 1 }),
        })
        : null;

    // パンくず（ジャンル ▸ 作者 ▸ シリーズ）。各レベル: 選択済み=値 / 通過済みで未選択=
    // 「すべて」/ 未到達=ラベル。タップでそのレベルへジャンプ（step を合わせる）。
    const crumbs = [];
    for (let i = 0; i < BROWSE_LEVELS.length; i++) {
        const lv = BROWSE_LEVELS[i];
        const value = sel[lv.column] || "";
        let text;
        if (value) text = value;            // 選択済み
        else if (i < step) text = "すべて";  // 通過済みで未選択（=すべて）
        else text = lv.label;               // 未到達（プレーンなラベル）
        const cls = i === step ? "crumb cur" : "crumb step";
        crumbs.push(el("button", {
            type: "button", class: cls,
            "aria-current": i === step ? "step" : null,
            onClick: () => navigate(uuid, { page: 1, q, sort, order, ...selParams, step: i }),
            text,
        }));
        if (i < BROWSE_LEVELS.length - 1) {
            crumbs.push(el("span", { class: "crumb-sep", text: "▸", "aria-hidden": "true" }));
        }
    }

    return el("div", { class: "stepper-bar" }, [
        back,
        el("nav", { class: "crumbs", "aria-label": "ステップ" }, crumbs),
    ]);
}

// ---- ページャ ---------------------------------------------------------------

function pager(uuid, { page, totalPages, total, perPage, q, sort, order, sel, step, deps }) {
    const { el } = deps;
    // browse 選択を navigate に載せ直す（ページ送り・per 変更で消さない）。
    // 狭幅 column の結果（step===3）ではページ送りでも step を保つ。
    const selParams = sel ? { g: sel.genre, a: sel.author, s: sel.series } : {};
    if (step != null) selParams.step = step;
    const prev = el("button", {
        type: "button", class: "pager-btn", text: "‹ 前",
        disabled: page <= 1,
        onClick: () => navigate(uuid, { page: page - 1, q, sort, order, ...selParams }),
    });
    const next = el("button", {
        type: "button", class: "pager-btn", text: "次 ›",
        disabled: page >= totalPages,
        onClick: () => navigate(uuid, { page: page + 1, q, sort, order, ...selParams }),
    });

    // per/scroll セレクタはツールバー行へ移設済み（無限モードでも見えるように常設）。
    // ページャは前後送り＋件数表示のみを担う。
    return el("div", { class: "pager" }, [
        prev,
        el("span", { class: "pager-info", text: `${page} / 全${totalPages}（${total}冊）` }),
        next,
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

    const lastUi = (book.lastPage != null && book.lastPage > 0) ? book.lastPage + 1 : null;
    const openAt = (ui) => {
        close();
        location.hash = `#/lib/${encodeURIComponent(uuid)}/read/${book.id}?p=${ui}`;
    };
    const readerActions = lastUi
        ? [ el("button", { type: "button", class: "btn-primary", text: "続きから読む", onClick: () => openAt(lastUi) }),
            el("button", { type: "button", class: "btn-secondary", text: "最初から", onClick: () => openAt(1) }),
            el("button", { type: "button", class: "btn-secondary", text: "閉じる", onClick: close }) ]
        : [ el("button", { type: "button", class: "btn-primary", text: "開く", onClick: () => openAt(1) }),
            el("button", { type: "button", class: "btn-secondary", text: "閉じる", onClick: close }) ];

    const modal = el("div", { class: "modal detail-modal", role: "dialog", "aria-label": "本の詳細" }, [
        el("div", { class: "detail-header" }, [
            coverEl,
            el("div", { class: "detail-headinfo" }, [
                el("h2", { class: "detail-title", text: book.title || "(無題)" }),
                book.author ? el("p", { class: "detail-author", text: book.author }) : null,
            ]),
        ]),
        rows.length ? el("div", { class: "detail-rows" }, rows) : null,
        el("div", { class: "modal-actions" }, readerActions),
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
    setOrder("asc");
    navigate(uuid, { page: 1, q: series || "", sort: "series", order: "asc" });
}

// ---- URL 遷移（状態を hash に反映） ------------------------------------------

/// books 画面の状態を hash に書き込んで遷移する。
/// 空の q・既定値（sort=title / order=sort の自然既定）は URL に載せない（短く保つ）。
/// browse 選択（g/a/s = ジャンル/作者/シリーズ）は値があるときだけ載せる。
export function buildBooksHash(uuid, { page = 1, q = "", sort = "title", order, g = "", a = "", s = "", step } = {}) {
    const params = [];
    if (page && page !== 1) params.push(`page=${page}`);
    if (q) params.push(`q=${encodeURIComponent(q)}`);
    if (sort && sort !== "title") params.push(`sort=${encodeURIComponent(sort)}`);
    // order はそのキーの自然既定と異なるときだけ URL に載せる。
    if (order && order !== (DEFAULT_ORDER[sort] || "asc")) {
        params.push(`order=${encodeURIComponent(order)}`);
    }
    if (g) params.push(`g=${encodeURIComponent(g)}`);
    if (a) params.push(`a=${encodeURIComponent(a)}`);
    if (s) params.push(`s=${encodeURIComponent(s)}`);
    // step は狭幅 column stepper の現在地（0=ジャンル/1=作者/2=シリーズ/3=結果）。
    // 0 は既定なので URL に載せない（短く保つ）。
    const stepN = parseInt(step, 10);
    if (Number.isFinite(stepN) && stepN > 0) params.push(`step=${stepN}`);
    const qs = params.length ? `?${params.join("&")}` : "";
    return `#/lib/${encodeURIComponent(uuid)}${qs}`;
}

function navigate(uuid, state) {
    location.hash = buildBooksHash(uuid, state);
}
