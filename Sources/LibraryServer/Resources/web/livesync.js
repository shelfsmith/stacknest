// SPDX-License-Identifier: MIT
// G8b: リモート即時同期（Web）。EventSource で /api/v1/events を購読し、現在開いている
// ライブラリの変更を検知したら onReload（内部で ~250ms デバウンス）を呼ぶ。
// EventSource は Authorization ヘッダを付けられないため ?token= クエリで認証する。
import { deviceToken, ensureSessionToken, invalidateSessionToken } from "./api.js";

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
///
/// G23 (#9/#10): クエリに載せるトークンを短命セッショントークンにするため async 化した。
/// 呼び出し側は await 不要（fire-and-forget で従来どおり使える）。
export async function startLiveSync(uuid, h) {
    handlers = h;
    if (es && curUuid === uuid) return;
    stopLiveSync();
    curUuid = uuid;
    firstOpen = true;
    // 交換に失敗した場合だけ従来どおり永続トークンへフォールバックする（同期が止まる方が困るため）。
    const token = (await ensureSessionToken()) || deviceToken() || "";
    // await 中に stopLiveSync()／別ライブラリへの切り替えが起きていたら、この接続は張らない。
    if (curUuid !== uuid) return;
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
        // CLOSED = 非2xx 等で恒久 fail（grant 失効／サーバ喪失／サーバ再起動）→ 復旧経路へ。
        // ★先に stopLiveSync() で stale な es を破棄してから onAuthLost() を呼ぶ。こうすると:
        //   ・真の認証失効: onAuthLost→route()→再取得 401→api() が #/pair へ（従来どおり）。
        //   ・非認証の恒久 fail（例: サーバ再起動中に再接続が非2xx）: route()→再取得 200→
        //     startLiveSync が es=null を見て新規接続を張り直す。破棄せず onAuthLost を
        //     呼ぶと、stale es が残り idempotent guard（同一 uuid で return）に阻まれ再購読が
        //     スキップされ「ライブ同期が無音で死ぬ」ため、必ず先に破棄する。
        if (es && es.readyState === EventSource.CLOSED) {
            const cb = handlers.onAuthLost;
            stopLiveSync();
            // G23 (#9/#10): 恒久 fail の原因が短命トークンの期限切れである可能性があるため捨てる。
            // 次回の startLiveSync が再交換する。永続トークンが生きていれば復旧経路はそのまま働く。
            invalidateSessionToken();
            cb();
        }
    };
}

/// 購読を停止する（ビュー離脱時）。保留中のデバウンスもクリア。
export function stopLiveSync() {
    if (reloadTimer) { clearTimeout(reloadTimer); reloadTimer = null; }
    if (es) { es.close(); es = null; }
    curUuid = null;
    firstOpen = true;
}
