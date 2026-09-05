// G48-3: foliate-js の位置 ⇄ 共有 locator（{spine, progress, cfi, engine}）の写像。純粋関数だけ。
// 共有の正は spine＋progress。cfi は同じエンジン（"foliate"）のときだけ復元に使う（親 spec の互換規則）。
export const ENGINE = "foliate";

const num = (x, lo, hi, fallback) => {
    // null/undefined/"" は Number() で 0 になり下限に丸まってしまう（自走 smoke で A+ が 0.561 になった）。fallback を返す。
    if (x === null || x === undefined || x === "") return fallback;
    const n = Number(x);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, n));
};

/// foliate の renderer 'relocate' detail（{index, fraction}）と view.lastLocation.cfi から locator を作る。
export function toLocator({ index, fraction, cfi } = {}) {
    return {
        spine: Math.floor(num(index, 0, Number.MAX_SAFE_INTEGER, 0)),
        progress: num(fraction, 0, 1, 0),
        cfi: typeof cfi === "string" && cfi ? cfi : null,
        engine: ENGINE,
    };
}

/// 復元先。foliate 由来の cfi なら文字列（view.goTo(cfi)）、それ以外は {index, anchor}（view.renderer.goTo）。
export function restoreTarget(locator) {
    if (!locator || typeof locator !== "object") return null;
    if (locator.engine === ENGINE && typeof locator.cfi === "string" && locator.cfi) return locator.cfi;
    return { index: Math.floor(num(locator.spine, 0, Number.MAX_SAFE_INTEGER, 0)), anchor: num(locator.progress, 0, 1, 0) };
}

/// 文字倍率（Mac の ViewerSettings.epubFontScale と同じ範囲）。
export function clampScale(x) { return num(x, 0.5, 3.0, 1.0); }
