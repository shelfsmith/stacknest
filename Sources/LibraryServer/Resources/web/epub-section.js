// SPDX-License-Identifier: MIT
// G54-S3d: テキスト EPUB の章が「画像 1 枚だけ」かを見分け、foliate-js の枠（余白・段組み）の値を決める。純粋関数だけ。
// foliate の paginator は全章に同じ枠（上下 48px・左右 7%・横長は 2 段組み）を掛け、その枠は章の文書の外側にある
// （章の中に CSS を入れても消えない）。画像の章ではこの枠を外し、文字の章に来たら既定値へ戻す
// （枠は foliate の要素全体に掛かるので、章ごとに切り替える）。

/// 画像の章で foliate の renderer に当てる属性。**`max-inline-size` を最後に置く**:
/// foliate はこの属性の変更のときだけ即座に再描画する（paginator.js の attributeChangedCallback）ので、
/// 他の値を先に入れておけば、その再描画も正しい値で行われる。
/// `max-inline-size` / `max-block-size` は「段の幅の上限」なので、画面より十分大きくして上限を無くす。
export const IMAGE_SECTION_ATTRS = Object.freeze({
    "margin": "0px",
    "gap": "0%",
    "max-column-count": "1",
    "max-block-size": "100000px",
    "max-inline-size": "100000px",
});

/// 章の文書が「画像 1 枚だけ」か（本文に文字が無く、img か svg がちょうど 1 つ）。
/// svg の中の image は svg 1 つとして数える。
export function isImageOnlySection(doc) {
    const body = doc?.body;
    if (!body) return false;
    if (String(body.textContent ?? "").trim() !== "") return false;
    const images = body.querySelectorAll("img").length + body.querySelectorAll("svg").length;
    return images === 1;
}

/// renderer へ当てる操作の列（[属性名, 値 or null]。null は removeAttribute＝既定値へ戻す）。
/// 前の章と同じ種類なら空（属性を触らない＝余計な再描画を起こさない）。
export function layoutChanges(wasImageOnly, isImageOnly) {
    if (Boolean(wasImageOnly) === Boolean(isImageOnly)) return [];
    return Object.entries(IMAGE_SECTION_ATTRS).map(([name, value]) => [name, isImageOnly ? value : null]);
}

/// 章の文書の中のクリックでバーを出し入れするか。リンク（目次・注）・文字選択中・foliate が
/// 既に処理したクリック（リンクは foliate が preventDefault する）では出し入れしない。
export function shouldToggleBar({ defaultPrevented, onLink, hasSelection }) {
    return !defaultPrevented && !onLink && !hasSelection;
}
