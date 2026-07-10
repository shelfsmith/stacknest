// SPDX-License-Identifier: MIT
// G8b: リモート即時同期（Web）。EventSource で /api/v1/events を購読し、現在開いている
// ライブラリの変更を検知したら onReload（内部で ~250ms デバウンス）を呼ぶ。
// EventSource は Authorization ヘッダを付けられないため ?token= クエリで認証する。
import { deviceToken } from "./api.js";

const EVENT_NAMES = ["bookChanged", "structureChanged", "settingsChanged"];
const DEBOUNCE_MS = 250;

let es = null;
let curUuid = null;
let firstOpen = true;
let handlers = { onReload: () => {}, onAuthLost: () => {} };
let reloadTimer = null;

// バースト（ホストの一括編集＝多数のイベント）を ~250ms 窓で 1 回の反映に集約する。
function scheduleReload() {
    if (reloadTimer) clearTimeout(reloadTimer);
    reloadTimer = setTimeout(() => { reloadTimer = null; handlers.onReload(); }, DEBOUNCE_MS);
}

/// 指定ライブラリの購読を開始する。既に同一 uuid で接続中なら handlers 更新のみ（張り替えない）。
export function startLiveSync(uuid, h) {
    handlers = h;
    if (es && curUuid === uuid) return;
    stopLiveSync();
    curUuid = uuid;
    firstOpen = true;
    const token = deviceToken() || "";
    es = new EventSource(`/api/v1/events?token=${encodeURIComponent(token)}`);
    for (const name of EVENT_NAMES) {
        es.addEventListener(name, (ev) => {
            let d;
            try { d = JSON.parse(ev.data); } catch { return; }
            if (d && d.library === curUuid) scheduleReload();
        });
    }
    es.onopen = () => {
        // 初回はビュー初期ロード済みなのでスキップ。2 回目以降（再接続）は取りこぼし回収。
        if (firstOpen) { firstOpen = false; return; }
        scheduleReload();
    };
    es.onerror = () => {
        // CONNECTING = ブラウザが自動再接続中（transient）→ 放置。
        // CLOSED = 非2xx 等で恒久 fail（grant 失効/サーバ喪失）→ auth-lost 経路へ。
        if (es && es.readyState === EventSource.CLOSED) handlers.onAuthLost();
    };
}

/// 購読を停止する（ビュー離脱時）。保留中のデバウンスもクリア。
export function stopLiveSync() {
    if (reloadTimer) { clearTimeout(reloadTimer); reloadTimer = null; }
    if (es) { es.close(); es = null; }
    curUuid = null;
    firstOpen = true;
}
