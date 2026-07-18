// SPDX-License-Identifier: MIT
// StackNest Web — 手組み rAF スプリング（外部ライブラリ不使用・G17 Pack B）。
//
// SwiftUI の `spring(response:dampingFraction:)` に倣い、臨界〜過減衰の調和振動子を
// 陽的オイラー法で毎フレーム積分する。damping=1（既定）は臨界減衰＝オーバーシュート無し。
// transform/opacity の駆動専用に絞った軽量実装（汎用アニメーションライブラリは狙わない）。
// Pack C（他画面のトランジション）でも import して再利用する想定。

const TWO_PI = Math.PI * 2;

/// 1 フレーム分の状態更新。x=現在値, v=現在速度, target=目標値。
/// omega0 = 2π / response（response ≈ 特性時間）、c = 2 * damping * omega0。
/// damping=1 で "c = 2*sqrt(k)" となり臨界減衰（このコードの damping はそのまま減衰比 ζ）。
function stepSpring(x, v, target, damping, response, dt) {
    const omega0 = TWO_PI / Math.max(response, 0.001);
    const k = omega0 * omega0;
    const c = 2 * damping * omega0;
    const ax = -k * (x - target) - c * v;
    const nv = v + ax * dt;
    const nx = x + nv * dt;
    return [nx, nv];
}

/// 表示上もう動いて見えない程度に静止したか。しきい値は「移動距離（amplitude）」に対する
/// 相対値にする（絶対 0.01 固定だと、opacity のような 0〜1 の値と translateX の 0〜100(%)
/// のような値とでスケールが 100 倍違うため、後者だけ収束に何倍も時間がかかってしまう
/// ＝ response で意図した体感時間からズレる）。
function isSettled(x, v, target, amplitude) {
    const eps = Math.max(1e-4, amplitude * 0.01);
    return Math.abs(x - target) < eps && Math.abs(v) < eps * 6;
}

/**
 * rAF ベースの手組みスプリングアニメーション。呼び出し時点の現在値（from）から開始する
 * ため中断→再開しても値が飛ばない（=interruptible）。transform/opacity 駆動専用。
 *
 * @param {object} opts
 * @param {number} opts.from - 開始値（呼び出し時点の「現在値」であるべき）。
 * @param {number} opts.to - 目標値。
 * @param {number} [opts.velocity=0] - 初速（中断直後の値を渡せば速度連続的に再開できる。今回は未使用）。
 * @param {number} [opts.damping=1] - 減衰比 ζ。1 = 臨界減衰（オーバーシュート無し・既定）。
 * @param {number} [opts.response=0.35] - 応答時間（秒）。SwiftUI の response と同義。
 * @param {(value:number)=>void} [opts.onUpdate] - 毎フレーム呼ばれる。
 * @param {()=>void} [opts.onDone] - 静止して停止したときに一度だけ呼ばれる（cancel() 時は呼ばれない）。
 * @returns {{cancel: () => void}} 中断用ハンドル（token）。
 */
export function spring({ from, to, velocity = 0, damping = 1, response = 0.35, onUpdate, onDone } = {}) {
    let x = from;
    let v = velocity;
    let rafId = null;
    let lastT = null;
    let cancelled = false;
    // 収束判定のスケール基準。中断→再開で from が target 寄りに縮んでいてもフレーム内で
    // 更新されないよう、最初の振幅（絶対値の最大）を固定で使う。
    const amplitude = Math.max(Math.abs(to - from), 1e-4);

    function frame(t) {
        if (cancelled) return;
        if (lastT === null) lastT = t;
        // dt をクランプ（バックグラウンドタブ復帰等の巨大な gap で発散しないように）。
        const dt = Math.min(0.05, Math.max(0, (t - lastT) / 1000));
        lastT = t;
        [x, v] = stepSpring(x, v, to, damping, response, dt);

        if (isSettled(x, v, to, amplitude)) {
            x = to;
            if (typeof onUpdate === "function") onUpdate(x);
            rafId = null;
            if (typeof onDone === "function") onDone();
            return;
        }
        if (typeof onUpdate === "function") onUpdate(x);
        rafId = requestAnimationFrame(frame);
    }

    rafId = requestAnimationFrame(frame);

    return {
        /// アニメーションを即座に停止する。onUpdate/onDone はこれ以降呼ばれない
        /// （呼び出し側が値を最終状態へ揃える処理は自前で行うこと）。
        cancel() {
            cancelled = true;
            if (rafId !== null) { cancelAnimationFrame(rafId); rafId = null; }
        },
    };
}
