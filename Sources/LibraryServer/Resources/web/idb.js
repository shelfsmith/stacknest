// SPDX-License-Identifier: MIT
// IndexedDB バイトキャッシュ。圧縮済みページバイト列を Blob で保存する。
// HTTPS 限定の Cache Storage API は使わず IndexedDB（HTTP でも動く）。将来 HTTPS 化で差し替え可能な薄い層。
const DB_NAME = "stacknest";
const STORE = "pages";
let dbPromise = null;

function openDB() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise((resolve, reject) => {
        const req = indexedDB.open(DB_NAME, 1);
        req.onupgradeneeded = () => {
            const db = req.result;
            if (!db.objectStoreNames.contains(STORE)) {
                const os = db.createObjectStore(STORE, { keyPath: "key" });
                os.createIndex("byAtime", "atime");
                os.createIndex("byBook", "book");
            }
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
    });
    return dbPromise;
}
function tx(db, mode) { return db.transaction(STORE, mode).objectStore(STORE); }
function reqP(r) { return new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); }); }

export function cacheKey(uuid, bookId, apiIndex, maxw) {
    return `${uuid}|${bookId}|${apiIndex}|${maxw ?? "full"}`;
}
export async function getPage(key) {
    try {
        const db = await openDB();
        const rec = await reqP(tx(db, "readonly").get(key));
        if (!rec) return null;
        try { const w = tx(db, "readwrite"); rec.atime = Date.now(); w.put(rec); } catch {}
        return rec.blob;
    } catch { return null; }
}
export async function putPage(key, book, blob) {
    try {
        const db = await openDB();
        await reqP(tx(db, "readwrite").put({ key, book, blob, bytes: blob.size, atime: Date.now() }));
    } catch {}
}
export async function totalBytes() {
    try {
        const db = await openDB();
        let sum = 0;
        await new Promise((res) => {
            const cur = tx(db, "readonly").openCursor();
            cur.onsuccess = () => { const c = cur.result; if (!c) return res(); sum += (c.value.bytes || 0); c.continue(); };
            cur.onerror = () => res();
        });
        return sum;
    } catch { return 0; }
}
export async function evictToLimit(limitBytes, protectedKeys = new Set()) {
    try {
        const db = await openDB();
        let total = await totalBytes();
        if (total <= limitBytes) return;
        await new Promise((res) => {
            const store = tx(db, "readwrite");
            const cur = store.index("byAtime").openCursor();
            cur.onsuccess = () => {
                const c = cur.result;
                if (!c || total <= limitBytes) return res();
                const rec = c.value;
                if (!protectedKeys.has(rec.key)) { total -= (rec.bytes || 0); c.delete(); }
                c.continue();
            };
            cur.onerror = () => res();
        });
    } catch {}
}
export async function deleteBook(book) {
    try {
        const db = await openDB();
        await new Promise((res) => {
            const cur = tx(db, "readwrite").index("byBook").openCursor(IDBKeyRange.only(book));
            cur.onsuccess = () => { const c = cur.result; if (!c) return res(); c.delete(); c.continue(); };
            cur.onerror = () => res();
        });
    } catch {}
}
export async function clearAll() {
    try { const db = await openDB(); await reqP(tx(db, "readwrite").clear()); } catch {}
}
export async function deletePage(key) {
    try { const db = await openDB(); await reqP(tx(db, "readwrite").delete(key)); } catch {}
}
export const WEB_CACHE_TTL_MS = 7 * 24 * 3600 * 1000;   // 7日固定
const PURGE_INTERVAL_MS = 24 * 3600 * 1000;             // フルスキャンは 1 日 1 回に間引く
const PURGE_TS_KEY = "stacknest_last_purge";
export async function purgeExpired(maxAgeMs = WEB_CACHE_TTL_MS) {
    try {
        // 本を開くたびの全走査を避ける: 前回 purge から 24h 未満ならスキップ（best-effort・localStorage）。
        try {
            const last = Number(localStorage.getItem(PURGE_TS_KEY) || "0");
            if (Date.now() - last < PURGE_INTERVAL_MS) return;
            localStorage.setItem(PURGE_TS_KEY, String(Date.now()));
        } catch {}
        const db = await openDB();
        const cutoff = Date.now() - maxAgeMs;
        await new Promise((res) => {
            const cur = tx(db, "readwrite").index("byAtime").openCursor();
            cur.onsuccess = () => {
                const c = cur.result;
                if (!c) return res();
                if ((c.value.atime || 0) < cutoff) c.delete();
                c.continue();
            };
            cur.onerror = () => res();
        });
    } catch {}
}
