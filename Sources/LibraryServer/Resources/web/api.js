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

export function libToken(uuid) { return sessionStorage.getItem(`stacknest.libtoken.${uuid}`); }
export function saveLibToken(uuid, t) { sessionStorage.setItem(`stacknest.libtoken.${uuid}`, t); }
export function clearLibToken(uuid) { sessionStorage.removeItem(`stacknest.libtoken.${uuid}`); }

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

/// サーバ capability（認証不要・到達性確認にも使う）。
export async function serverInfo() {
    let res;
    try {
        res = await fetch("/api/v1/server/info");
    } catch (e) {
        throw new NetworkError(e);
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
}

/// ライブラリ一覧。
export function listLibraries() { return apiJSON("/libraries"); }

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
