// SPDX-License-Identifier: MIT
// リーダーのクライアント側設定（localStorage・端末永続）。
const KEY = "stacknest.reader.prefs";
const DEFAULTS = Object.freeze({
    tier3Enabled: true,                    // フル先読み（残り全頁）
    cacheLimitBytes: 600 * 1024 * 1024,    // IndexedDB キャッシュ上限（既定 600MB）
    clearCacheOnExit: false,               // リーダー終了時にキャッシュを消す
});
export function readerPrefs() {
    try {
        const raw = localStorage.getItem(KEY);
        if (!raw) return { ...DEFAULTS };
        return { ...DEFAULTS, ...JSON.parse(raw) };
    } catch { return { ...DEFAULTS }; }
}
export function setReaderPref(key, value) {
    const p = readerPrefs();
    p[key] = value;
    localStorage.setItem(KEY, JSON.stringify(p));
}
export { DEFAULTS as READER_PREF_DEFAULTS };
