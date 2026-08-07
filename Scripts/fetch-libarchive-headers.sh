#!/bin/bash
#
# fetch-libarchive-headers.sh
#
# 実行時にリンクされる Apple の libarchive（/usr/lib/libarchive.2.dylib）と
# 完全に同じバージョンのヘッダ（archive.h / archive_entry.h）を libarchive
# 公式リポジトリから取得し、Sources/ArchiveAdapter/Carchive/vendor/ に配置する。
#
# Apple の macOS SDK は libarchive のダイナミックライブラリと .tbd は同梱するが
# archive.h を同梱しない（詳細は Carchive.h のコメント参照）。そのため従来は
# Homebrew のヘッダ（バージョンが異なりうる）で代用していたが、これはヘッダと
# 実行時ライブラリのバージョンドリフトを招く。本スクリプトはヘッダを一切使わずに
# 実行時バージョンを検出し、そのバージョンのヘッダだけを取得することでドリフトを解消する。
#
# 安全設計:
#   - 取得したヘッダの ARCHIVE_VERSION_NUMBER が検出済みの実行時バージョンと
#     一致することを確認してから配置する（検証前は vendor/ に一切触れない）。
#   - ネットワーク不通・タグ不在・書き込み失敗など、いずれの失敗でも非ゼロで終了し、
#     既存の vendor/ をそのまま残す（黙って古いヘッダを残置することはしても、
#     壊れた/不一致のヘッダで上書きすることは絶対にしない）。
#   - 2 回目以降の実行は、既に一致していれば何もせず正常終了する（冪等）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CARCHIVE_DIR="$REPO_ROOT/Sources/ArchiveAdapter/Carchive"
VENDOR_DIR="$CARCHIVE_DIR/vendor"
# 差し替え中だけ使う作業ディレクトリ。VENDOR_DIR と同じファイルシステム上に置くことで、
# 最終配置を単一の mv（= 同一ファイルシステム内 rename）にでき、
# 「archive.h だけ新しくなって archive_entry.h は古いまま」のような半端な状態を避ける。
STAGING_DIR="$CARCHIVE_DIR/vendor.new.$$"
BACKUP_DIR="$CARCHIVE_DIR/vendor.old.$$"

HEADERS=(archive.h archive_entry.h)

# レビュー指摘（Critical）への対応: CARCHIVE_DIR への書き込みが恒常的に失敗する状況
# （パーミッション喪失・ディスクフル等）では、配置の mv だけでなくロールバックの mv も
# 同じ理由で失敗しうる。その場合に cleanup が STAGING_DIR/BACKUP_DIR を消してしまうと、
# ヘッダの唯一のコピーを自動削除することになり「復元しました」という嘘のメッセージと
# 組み合わさって vendor/ が丸ごと消失する。この変数が 1 の間は cleanup は両ディレクトリに
# 触れない（＝手動復旧できる状態を必ず残す）。
KEEP_WORK_DIRS_ON_FAILURE=0

# 一時ディレクトリ（検出用の C プローブをここで作業する）。
# 検証に通るまで VENDOR_DIR には一切書き込まない。
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-libarchive-headers.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
    if [[ "$KEEP_WORK_DIRS_ON_FAILURE" -eq 0 ]]; then
        # 失敗時に残りうる作業ディレクトリの掃除（正常終了時は既にリネーム済みで存在しない）。
        rm -rf "$STAGING_DIR"
        rm -rf "$BACKUP_DIR"
    fi
}
trap cleanup EXIT

fail() {
    echo "エラー: $*" >&2
    exit 1
}

version_number_from_header() {
    # ヘッダファイルから `#define ARCHIVE_VERSION_NUMBER <int>` の値を抜き出す。
    local header_path="$1"
    grep -m1 -E '^#define[[:space:]]+ARCHIVE_VERSION_NUMBER[[:space:]]+[0-9]+' "$header_path" \
        | awk '{print $3}'
}

# --- 1. 実行時バージョンをヘッダなしで検出する ---------------------------------
# archive_version_number() を自前 extern 宣言し、-larchive でリンク・実行する。
# ヘッダを一切 #include しないため、「取得したいヘッダ自体を使わないと検出できない」
# という循環を避けられる。
PROBE_SRC="$WORK_DIR/probe.c"
PROBE_BIN="$WORK_DIR/probe"
cat > "$PROBE_SRC" <<'EOF'
extern int archive_version_number(void);
#include <stdio.h>
int main(void) {
    printf("%d\n", archive_version_number());
    return 0;
}
EOF

if ! cc -o "$PROBE_BIN" "$PROBE_SRC" -larchive 2>"$WORK_DIR/probe-compile.log"; then
    cat "$WORK_DIR/probe-compile.log" >&2
    fail "実行時 libarchive のバージョン検出用プローブのビルドに失敗しました（-larchive でリンクできません）。"
fi


# レビュー指摘（Minor）への対応: プローブはコンパイルできても実行時にクラッシュしうる。
# 代入の右辺（コマンド置換）の失敗を明示的に検査して fail() 経由にしないと、
# set -e がそのままスクリプトを打ち切り、日本語の説明メッセージが出ないまま終了してしまう。
if ! RUNTIME_VERSION="$("$PROBE_BIN")"; then
    fail "実行時 libarchive のバージョン検出用プローブの実行に失敗しました（ビルドには成功したが、実行時にエラー終了しました）。"
fi
if ! [[ "$RUNTIME_VERSION" =~ ^[0-9]+$ ]]; then
    fail "実行時バージョンの検出結果が数値ではありません: '$RUNTIME_VERSION'"
fi

RUNTIME_MAJOR=$((RUNTIME_VERSION / 1000000))
RUNTIME_MINOR=$(((RUNTIME_VERSION / 1000) % 1000))
RUNTIME_PATCH=$((RUNTIME_VERSION % 1000))
RUNTIME_TAG="v${RUNTIME_MAJOR}.${RUNTIME_MINOR}.${RUNTIME_PATCH}"

# --- 2. 既に一致していれば何もしない（冪等） -----------------------------------
if [[ -f "$VENDOR_DIR/archive.h" ]]; then
    EXISTING_VERSION="$(version_number_from_header "$VENDOR_DIR/archive.h" || true)"
    if [[ "$EXISTING_VERSION" == "$RUNTIME_VERSION" ]]; then
        echo "vendor/ のヘッダは既に実行時ライブラリ（${RUNTIME_TAG} / ${RUNTIME_VERSION}）と一致しています。何もしません。"
        exit 0
    fi
fi

# --- 3. 取得する（STAGING_DIR へ。vendor/ にはまだ触れない） --------------------
BASE_URL="https://raw.githubusercontent.com/libarchive/libarchive/${RUNTIME_TAG}/libarchive"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

for header in "${HEADERS[@]}"; do
    if ! curl -fsSL "${BASE_URL}/${header}" -o "${STAGING_DIR}/${header}"; then
        # NOTE: bash 3.2（macOS 標準 /bin/bash）は「$var」の直後に区切りなしで
        # マルチバイト文字（全角括弧など）が続くと変数名の切り出しを誤ることがある。
        # 必ず ${var} の波括弧形式を使い、変数展開の直後に全角記号を置かない。
        fail "libarchive ${RUNTIME_TAG} の ${header} を取得できませんでした（ネットワーク不通、またはタグ不在の可能性があります: ${BASE_URL}/${header} ）。既存の vendor/ は変更していません。"
    fi
done

# --- 4. 検証してから配置する ----------------------------------------------------
FETCHED_VERSION="$(version_number_from_header "$STAGING_DIR/archive.h" || true)"
if [[ -z "$FETCHED_VERSION" ]]; then
    fail "取得した archive.h から ARCHIVE_VERSION_NUMBER を読み取れませんでした。既存の vendor/ は変更していません。"
fi
if [[ "$FETCHED_VERSION" != "$RUNTIME_VERSION" ]]; then
    fail "取得したヘッダのバージョン（${FETCHED_VERSION}）が検出した実行時バージョン（${RUNTIME_VERSION}）と一致しません。既存の vendor/ は変更していません。"
fi

# ここまで来て初めて vendor/ を書き換える。既存 vendor/ を退避してから STAGING_DIR を
# 一度の mv（= 同一ファイルシステム内なら atomic な rename）で vendor/ に据える。
# 万一この配置自体が失敗しても、退避した既存 vendor/ を必ず元へ戻す。
#
# レビュー指摘（Critical）への対応: CARCHIVE_DIR への書き込みが恒常的に失敗する状況
# （パーミッション喪失・ディスクフル等）では、配置の mv とロールバックの mv が
# 「同じ理由で」両方失敗しうる。以前の実装はロールバックの mv の成否を確認せずに
# 「復元しました」と表示していたため、両方失敗した場合に vendor/ が丸ごと消失した状態で
# 復元成功を主張する、という最悪の経路があった（レビューがフォールトインジェクションで実証）。
# 以下は各 mv の成否を個別に確認し、どの段階で何が起きたかを正直に報告する。
# 復元できない状態に陥った場合は KEEP_WORK_DIRS_ON_FAILURE を立てて、cleanup が
# STAGING_DIR/BACKUP_DIR（＝ヘッダの唯一のコピー）を削除しないようにする。
rm -rf "$BACKUP_DIR"
HAD_EXISTING_VENDOR=0
if [[ -d "$VENDOR_DIR" ]]; then
    HAD_EXISTING_VENDOR=1
    if ! mv "$VENDOR_DIR" "$BACKUP_DIR"; then
        # 退避そのものが失敗＝vendor/ にはまだ触れていない。取得済みヘッダは STAGING_DIR に残す。
        KEEP_WORK_DIRS_ON_FAILURE=1
        fail "既存の vendor/ の退避に失敗しました（書き込み失敗）。vendor/ 自体は変更していません。取得済みのヘッダは ${STAGING_DIR} に残しています（${CARCHIVE_DIR} への書き込み権限・空き容量を確認したうえで、不要なら手動で削除してください）。"
    fi
fi

if mv "$STAGING_DIR" "$VENDOR_DIR"; then
    # 新配置に成功。退避した旧 vendor はもう不要。
    rm -rf "$BACKUP_DIR"
    echo "libarchive ${RUNTIME_TAG}（${RUNTIME_VERSION}）のヘッダを vendor/ に取得しました。"
    exit 0
fi

if [[ "$HAD_EXISTING_VENDOR" -eq 0 ]]; then
    # 元々 vendor/ は存在しなかった。新規配置だけが失敗。
    KEEP_WORK_DIRS_ON_FAILURE=1
    fail "vendor/ への新ヘッダの配置に失敗しました（書き込み失敗）。vendor/ はもともと存在しませんでした。取得したヘッダは ${STAGING_DIR} に残しています（${CARCHIVE_DIR} への書き込み権限・空き容量を確認してください）。"
fi

if mv "$BACKUP_DIR" "$VENDOR_DIR"; then
    fail "vendor/ への新ヘッダの配置に失敗しました（書き込み失敗）。既存の vendor/（旧バージョン）は復元しました。"
else
    # 配置とロールバックの両方が失敗＝同一ディレクトリへの書き込みが継続して失敗している。
    # これ以上は自動復旧できないため、削除は一切行わず両方のコピーを手動復旧用に残す。
    KEEP_WORK_DIRS_ON_FAILURE=1
    fail "vendor/ への新ヘッダの配置と、既存 vendor/ の復元の両方に失敗しました（${CARCHIVE_DIR} への書き込みが継続して失敗しています）。自動復旧はできないため、削除は一切行っていません。次を手動で確認してください: 新しいヘッダ = ${STAGING_DIR} / 旧ヘッダ（退避済み） = ${BACKUP_DIR} 。書き込み権限・空き容量を確認したうえで、どちらかを ${VENDOR_DIR} へ配置し直してください。"
fi
