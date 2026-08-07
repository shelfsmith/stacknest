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

# 一時ディレクトリ（検出用の C プローブをここで作業する）。
# 検証に通るまで VENDOR_DIR には一切書き込まない。
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fetch-libarchive-headers.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
    # 失敗時に残りうる作業ディレクトリの掃除（正常終了時は既にリネーム済みで存在しない）。
    rm -rf "$STAGING_DIR"
    rm -rf "$BACKUP_DIR"
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

RUNTIME_VERSION="$("$PROBE_BIN")"
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
rm -rf "$BACKUP_DIR"
if [[ -d "$VENDOR_DIR" ]]; then
    mv "$VENDOR_DIR" "$BACKUP_DIR"
fi
if mv "$STAGING_DIR" "$VENDOR_DIR"; then
    rm -rf "$BACKUP_DIR"
else
    if [[ -d "$BACKUP_DIR" ]]; then
        mv "$BACKUP_DIR" "$VENDOR_DIR"
    fi
    fail "vendor/ への配置に失敗しました（書き込み失敗）。既存の vendor/ を復元しました。"
fi

echo "libarchive ${RUNTIME_TAG}（${RUNTIME_VERSION}）のヘッダを vendor/ に取得しました。"
