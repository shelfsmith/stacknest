// SPDX-License-Identifier: MIT
import { cacheKey, getPage, putPage, evictToLimit, deletePage } from "./idb.js";

const CONCURRENCY = 3;

export class PrefetchEngine {
    /// ctx: { uuid, bookId, pageCount, maxw, book, version, tier3Enabled, cacheLimitBytes,
    ///        fetchPageBlob(uuid, bookId, apiIndex, maxw, signal, version)
    ///            -> Promise<{ blob, noStore }> }
    /// review follow-up Finding 1: fetchPageBlob の戻り値は `Blob` 単体ではなく
    /// `{ blob, noStore }`。`noStore`（サーバの `Cache-Control: no-store` ＝ ?v= が現在版と
    /// 食い違う）が true のときは、そのバイトを呼び出し元へ返す（表示には使う）が
    /// `putPage` は必ずスキップする ―― でないと relink 直後に届いた「別版のバイト」が
    /// IndexedDB の旧版キーの下に固定され、後で元の版へ relink し戻ったときにキーがヒットして
    /// 誤ったページが（7日 purge まで）表示され続ける（サーバ側 no-store が防ごうとしている
    /// core の再発）。
    /// version: manifest.etag（正規化済み・G4d 層2）。relink 等で本体が差し替わると変わり、
    /// 旧版キーとは別キーになるため IndexedDB 上の旧ページを誤って再利用しない。
    constructor(ctx) {
        this.ctx = ctx;
        // テスト容易化（review follow-up Finding 1）: fetchPageBlob と同様に putPage も
        // ctx から差し替え可能にする（省略時は実装＝idb.js の putPage）。実 IndexedDB に依存せず
        // 「no-store 応答のときは保存しなかった」を直接観測できるようにするためのフック。
        this._putPage = ctx.putPage ?? putPage;
        this.current = 0;
        this.skipStride = 10;
        this.inFlight = new Map();   // apiIndex -> { promise, controller, tier }
        this.stopped = false;
        this.activeWindow = new Set();
        this._queue = [];
    }

    stop() {
        this.stopped = true;
        for (const { controller } of this.inFlight.values()) controller.abort();
        this.inFlight.clear();
    }

    setCurrentPage(apiIndex) {
        this.current = apiIndex;
        this._recompute();
        this._pump();
    }

    async requestPage(apiIndex, bypass = false) {
        const key = cacheKey(this.ctx.uuid, this.ctx.bookId, apiIndex, this.ctx.maxw, this.ctx.version);
        if (bypass) {
            await deletePage(key);
        } else {
            const cached = await getPage(key);
            if (cached) return cached;
        }
        try {
            return await this._fetch(apiIndex, 0);
        } catch (e) {
            // tier3 abort の巻き添えになった場合は 1 回だけリトライ
            if (e && e.name === "AbortError" && !this.stopped) {
                if (!bypass) { const again = await getPage(key); if (again) return again; }
                return this._fetch(apiIndex, 0); // inFlight は finally で削除済み
            }
            throw e;
        }
    }

    async requestFullResolution(apiIndex) {
        const key = cacheKey(this.ctx.uuid, this.ctx.bookId, apiIndex, null, this.ctx.version);
        const cached = await getPage(key);
        if (cached) return cached;
        // HTTP キャッシュ追随修正: version を渡し忘れると、この経路だけ URL がバージョンレスの
        // ままになり「半分だけ版管理された」状態（本 bug の再発パターン）になる。
        const { blob, noStore } = await this.ctx.fetchPageBlob(this.ctx.uuid, this.ctx.bookId, apiIndex, undefined, undefined, this.ctx.version);
        // review follow-up Finding 1: no-store（版食い違い）応答は IndexedDB に残さない。
        if (!noStore) await this._putPage(key, this.ctx.book, blob);
        return blob;
    }

    _recompute() {
        const n = this.ctx.pageCount, cur = this.current;
        const order = [];
        const push = (i) => { if (i >= 0 && i < n && !order.includes(i)) order.push(i); };
        for (let d = 1; d <= 6; d++) push(cur + d);
        for (let d = 1; d <= 2; d++) push(cur - d);
        const fwd = cur + this.skipStride, back = cur - this.skipStride;
        push(fwd); push(fwd + 1); push(fwd - 1); push(back); push(back + 1); push(back - 1);
        if (this.ctx.tier3Enabled) {
            for (let d = 1; d < n; d++) { push(cur + d); push(cur - d); }
        }
        this._queue = order;
        this.activeWindow = new Set();
        for (let d = -2; d <= 6; d++) {
            const i = cur + d;
            if (i >= 0 && i < n) this.activeWindow.add(cacheKey(this.ctx.uuid, this.ctx.bookId, i, this.ctx.maxw, this.ctx.version));
        }
        const keep = new Set(this._queue.slice(0, 8));
        for (const [idx, h] of this.inFlight) {
            if (h.tier >= 3 && !keep.has(idx)) { h.controller.abort(); this.inFlight.delete(idx); }
        }
    }

    async _pump() {
        if (this.stopped) return;
        while (this.inFlight.size < CONCURRENCY && this._queue.length > 0) {
            const idx = this._queue.shift();
            const key = cacheKey(this.ctx.uuid, this.ctx.bookId, idx, this.ctx.maxw, this.ctx.version);
            const hit = await getPage(key);
            if (hit) continue;
            if (this.inFlight.has(idx)) continue;
            this._fetch(idx, this._queue.length === 0 ? 3 : 1).catch(() => {});
        }
    }

    async _fetch(apiIndex, tier) {
        // 二重 fetch ガード: 同一 apiIndex がすでに in-flight なら既存 promise を返す。
        // 新要求の tier がより高優先（値が小さい）なら tier を引き下げ → _recompute の abort 対象から外す。
        const existing = this.inFlight.get(apiIndex);
        if (existing) {
            if (tier < existing.tier) existing.tier = tier;
            return existing.promise;
        }
        // stop() 後のフェッチは即拒否
        if (this.stopped) return Promise.reject(new Error("stopped"));

        const key = cacheKey(this.ctx.uuid, this.ctx.bookId, apiIndex, this.ctx.maxw, this.ctx.version);
        const controller = new AbortController();
        const promise = (async () => {
            try {
                const { blob, noStore } = await this.ctx.fetchPageBlob(
                    this.ctx.uuid, this.ctx.bookId, apiIndex, this.ctx.maxw, controller.signal, this.ctx.version);
                // review follow-up Finding 1: no-store（版食い違い）応答は IndexedDB に残さない。
                if (!noStore) {
                    await this._putPage(key, this.ctx.book, blob);
                    await evictToLimit(this.ctx.cacheLimitBytes, this.activeWindow);
                }
                return blob;
            } finally {
                this.inFlight.delete(apiIndex);
                this._pump();
            }
        })();
        this.inFlight.set(apiIndex, { promise, controller, tier });
        return promise;
    }
}
