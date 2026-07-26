// SPDX-License-Identifier: MIT
// 認証付き fetch ラッパ。401→再ペアリング、ロック庫 403→呼び出し側が unlock フローへ。
// デバイストークンは localStorage（端末永続）、ライブラリトークンは sessionStorage（タブ寿命）。

const TOKEN_KEY = "stacknest.token";

export function deviceToken() { return localStorage.getItem(TOKEN_KEY); }
export function saveDeviceToken(t) { localStorage.setItem(TOKEN_KEY, t); }
export function clearDeviceToken() { localStorage.removeItem(TOKEN_KEY); }
export function hasDeviceToken() {
    const t = deviceToken();
    return typeof t === "string" && t.length > 0;
}

// G23 (#9/#10): URL クエリに載せる用の短命セッショントークン。
// EventSource と <img> はカスタムヘッダを送れないため認証情報を URL に置かざるを得ないが、
// 永続トークンを載せるとブラウザ履歴やプロキシログに残る。メモリのみで保持し永続化しない。
let sessionTokenValue = null;
let sessionTokenPromise = null;

/// 現在保持している短命トークン（未取得なら null）。URL 組み立て前に ensureSessionToken() を待つこと。
export function currentSessionToken() { return sessionTokenValue; }

/// 短命トークンを取得する。同時呼び出しは 1 本の交換にまとめる。
export async function ensureSessionToken() {
    if (sessionTokenValue) return sessionTokenValue;
    if (!sessionTokenPromise) {
        sessionTokenPromise = (async () => {
            try {
                const res = await fetch("/api/v1/session", {
                    method: "POST",
                    headers: { Authorization: `Bearer ${deviceToken() || ""}` },
                });
                if (!res.ok) return null;
                const body = await res.json();
                sessionTokenValue = body.sessionToken || null;
                return sessionTokenValue;
            } catch {
                return null;   // 取得失敗時は呼び出し側が従来どおり動けるよう null を返す
            } finally {
                sessionTokenPromise = null;
            }
        })();
    }
    return sessionTokenPromise;
}

/// 期限切れ（401）を検出したら捨てて次回再取得させる。
export function invalidateSessionToken() { sessionTokenValue = null; }

export function libToken(uuid) { return sessionStorage.getItem(`stacknest.libtoken.${uuid}`); }
export function saveLibToken(uuid, t) { sessionStorage.setItem(`stacknest.libtoken.${uuid}`, t); }

/// 401 はトークン破棄してペアリング画面へ飛ばす際に投げる番兵エラー。
export class UnauthorizedError extends Error {
    constructor() { super("unauthorized"); this.name = "UnauthorizedError"; }
}
/// ネットワーク到達不能（サーバ停止等）。呼び出し側でトースト + 再試行に使う。
export class NetworkError extends Error {
    constructor(cause) { super("network"); this.name = "NetworkError"; this.cause = cause; }
}

/// 認証付き fetch。`/api/v1` を自動付与し Bearer / X-Library-Token を載せる。
/// 401 は UnauthorizedError、fetch 自体の失敗は NetworkError を投げる。
/// 403（ロック庫）は Response をそのまま返すので呼び出し側で unlock フローへ。
export async function api(path, { libraryUUID, ...options } = {}) {
    const headers = { ...(options.headers || {}), Authorization: `Bearer ${deviceToken() || ""}` };
    if (libraryUUID && libToken(libraryUUID)) headers["X-Library-Token"] = libToken(libraryUUID);
    let res;
    try {
        res = await fetch(`/api/v1${path}`, { ...options, headers });
    } catch (e) {
        throw new NetworkError(e);
    }
    if (res.status === 401) {
        clearDeviceToken();
        location.hash = "#/pair";
        throw new UnauthorizedError();
    }
    return res;
}

/// JSON を返す GET ヘルパ。!ok かつ 403 でない場合は Error を投げる。
export async function apiJSON(path, opts = {}) {
    const res = await api(path, opts);
    if (!res.ok) {
        const err = new Error(`HTTP ${res.status}`);
        err.status = res.status;
        throw err;
    }
    return res.json();
}

/// ライブラリ一覧。
export function listLibraries() { return apiJSON("/libraries"); }

/// 本の manifest（pageCount / direction("rtl"|"ltr"|null) / format / etag）。
export function fetchManifest(uuid, bookId) {
    return apiJSON(`/libraries/${encodeURIComponent(uuid)}/books/${bookId}/manifest`, { libraryUUID: uuid });
}

/// 4.2c-11: 隣接巻（dir="next"|"prev"）。該当なしは reply.book が null。
export async function fetchAdjacent(uuid, bookId, dir) {
    const reply = await apiJSON(
        `/libraries/${encodeURIComponent(uuid)}/books/${bookId}/adjacent?dir=${dir}`,
        { libraryUUID: uuid });
    return reply.book; // BookListItemDTO | null
}

/// ページ画像 URL のクエリ文字列を組み立てる（fetchPageBlob と分離し純関数としてテスト可能にする）。
/// maxw 省略/0 以下は原寸で付けない。version は manifest.etag を normalizeVersion 済みの値
/// （reader.js が PrefetchEngine ctx.version 経由で渡す）をそのまま使うこと — キャッシュキーの
/// 版と URL の版がずれると、relink 後の再取得が旧 immutable エントリで即答される本 bug が
/// 半分だけ直った状態で再発する。
export function pageQuery(maxw, version) {
    const params = [];
    if (maxw && maxw > 0) params.push(`maxw=${maxw}`);
    if (version) params.push(`v=${encodeURIComponent(version)}`);
    return params.length ? `?${params.join("&")}` : "";
}

/// ページ画像を取得（apiIndex は 0 始まり・maxw 省略時は原寸）。
/// AbortError は素通し（中断は正常系）。それ以外の !ok は status 付き Error。
/// 戻り値は `{ blob, noStore }`（review follow-up Finding 1 で `Blob` 単体から変更）。
/// `noStore` はサーバ応答の `Cache-Control: no-store`（?v= が現在版と食い違う＝relink 直後の
/// 旧版 URL）を表す。呼び出し側（prefetch.js）はバイト自体は表示に使ってよいが、
/// `noStore === true` のときは IndexedDB（putPage）への保存を必ずスキップすること
/// ―― でないと、relink で B に切り替わった直後に古い版キー(vA)の URL へ届いた B のバイトが
/// IndexedDB の vA キーの下に固定され、後で A に relink し戻ったとき A のキーが即ヒットして
/// B のページが（7日 purge まで）表示され続ける（本 no-store 機構が守ろうとしている core の再発）。
///
/// HTTP キャッシュ追随修正（G4d 見落とし fix）: ページ画像は `Cache-Control: immutable` の
/// 長期キャッシュ対象だが、URL がバージョンレスだと relink 後もブラウザの HTTP キャッシュが
/// 古いバイトを immutable として返し続け、それが新しい IndexedDB バージョンキーの下に固定
/// されてしまう（stale が sticky になる＝本 bug の core）。cover（books.js coverURL の `?v=`）
/// と同じ設計で、version がある時は `?v=` を URL に織り込んで immutable を健全化し
/// （同じ URL の中身は本当に変わらない＝未変更版は無料でキャッシュヒットする）、version が
/// 無い（manifest 取得失敗等のフォールバック）ときだけ `cache: "reload"` でブラウザキャッシュを
/// 明示バイパスする（版不明な URL の immutable エントリを信用しない）。
export async function fetchPageBlob(uuid, bookId, apiIndex, maxw, signal, version) {
    const q = pageQuery(maxw, version);
    const opts = { libraryUUID: uuid, signal };
    if (!version) opts.cache = "reload";   // 版不明フォールバック: 今日の URL 形のまま HTTP キャッシュだけ避ける
    const res = await api(`/libraries/${encodeURIComponent(uuid)}/books/${bookId}/pages/${apiIndex}${q}`, opts);
    if (!res.ok) { const e = new Error(`HTTP ${res.status}`); e.status = res.status; throw e; }
    const noStore = (res.headers.get("cache-control") || "").toLowerCase().includes("no-store");
    return { blob: await res.blob(), noStore };
}

/// 進行状況の書き込み（apiIndex は 0 始まり）。!ok は status 付き Error。
export async function postProgress(uuid, bookId, apiIndex) {
    const res = await api(`/libraries/${encodeURIComponent(uuid)}/books/${bookId}/progress`,
        { libraryUUID: uuid, method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ page: apiIndex }) });
    if (!res.ok) { const e = new Error(`HTTP ${res.status}`); e.status = res.status; throw e; }
}

/// 本のページ方向を DB に書き戻す（"rtl" | "ltr" | null）。!ok は status 付き Error。
export async function postDirection(uuid, bookId, direction) {
    const res = await api(`/libraries/${encodeURIComponent(uuid)}/books/${bookId}/direction`,
        { libraryUUID: uuid, method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ direction }) });
    if (!res.ok) { const e = new Error(`HTTP ${res.status}`); e.status = res.status; throw e; }
}

/// G17 T6b: 特定ページの単頁/見開き override を書き戻す（page: apiIndex(0始まり)、
/// mode: 0=forcePair / 1=forceSolo / null=クリア＝自動判定に戻す）。RW 必須（!ok は status 付き Error）。
export async function postPageLayout(uuid, bookId, page, mode) {
    const res = await api(`/libraries/${encodeURIComponent(uuid)}/books/${bookId}/page-layout`,
        { libraryUUID: uuid, method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ page, mode }) });
    if (!res.ok) { const e = new Error(`HTTP ${res.status}`); e.status = res.status; throw e; }
}

/// browse 制約（[{column,value},...] 形式）→ &browse=<URL-encoded JSON>。空なら ""。
/// constraints は [{column: "genre", value: "SF"}, ...] の配列。
export function browseParam(constraints) {
    if (!constraints || constraints.length === 0) return "";
    return `&browse=${encodeURIComponent(JSON.stringify(constraints))}`;
}

/// ファセット候補値。field は SQL 列名（"genre"|"author"|"series"|"neta"|"keyword_a"|"keyword_b"|"keyword_c"）。
/// upper browse 制約（[{column,value},...]）と検索 q で絞った distinct 値の配列を返す。
/// サーバは [String] をそのまま返すため、戻り値は string の配列。
export function fetchFacet(uuid, field, { browse = [], q = "" } = {}) {
    const path = `/libraries/${encodeURIComponent(uuid)}/facets/${encodeURIComponent(field)}`
        + `?q=${encodeURIComponent(q)}${browseParam(browse)}`;
    return apiJSON(path, { libraryUUID: uuid });
}

/// ロック庫の解錠。成功で libraryToken を sessionStorage に保存する。
/// 認証失敗（パスワード違い）は false を返す。
export async function unlockLibrary(uuid, password) {
    const res = await api(`/libraries/${encodeURIComponent(uuid)}/unlock`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ password }),
    });
    if (res.status === 401 || res.status === 403 || res.status === 400) return false;
    if (!res.ok) {
        const err = new Error(`HTTP ${res.status}`);
        err.status = res.status;
        throw err;
    }
    const json = await res.json();
    if (json && typeof json.libraryToken === "string") {
        saveLibToken(uuid, json.libraryToken);
        return true;
    }
    return false;
}
