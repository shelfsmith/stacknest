#!/usr/bin/env bash
# gh の書き込み系操作（issue / comment / pr / release など）を、active アカウントが期待どおりの
# ときだけ通す番人。このプロジェクトは公開名義を 1 つに固定しているため、別アカウントからの
# 投稿は取り消せない事故になる（Issue の削除権限は相手側にある）。
# 使い方: Scripts/gh-guarded.sh issue create --repo owner/name --title ... --body-file ...
# 期待アカウントは env STACKNEST_GH_LOGIN で上書きできる（既定: shelfsmith）。
set -euo pipefail
EXPECTED="${STACKNEST_GH_LOGIN:-shelfsmith}"
# GITHUB_TOKEN / GH_TOKEN があると gh の active アカウントが無視されるので、判定前に外す
unset GITHUB_TOKEN GH_TOKEN
ACTUAL="$(gh api user --jq .login 2>/dev/null || true)"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "gh-guarded: active gh account is '${ACTUAL:-none}', expected '$EXPECTED'. Refusing: gh $*" >&2
  echo "gh-guarded: run 'gh auth switch --user $EXPECTED' and retry." >&2
  exit 1
fi
# 2026-10-01: 投稿の本文・タイトルに個人識別子（実名など）が無いことを確かめてから投稿する。
# 検査するもの:
#   - 引数すべて（--title / --body / -f などの直接の値）
#   - 本文を取る指定の中身: --body-file / --notes-file / --input（区切りの形も = の形も）、gh api 以外の -F、
#     gh api の -F / --field の「キー=@パス」の値（-f / --raw-field の値はそのままの文字列なので読まない）。通常のファイルならそのまま読み、"-"（標準入力）や
#     パイプ（<(...)）などは一度一時ファイルに受けてから検査し、gh にはその一時ファイルを渡す。
#     読めない指定は止める（検査を素通りさせない）
#   - それ以外で既存の通常のファイルを指す引数（gist のファイルなど）
# gh api の -F は「キー=値」の指定で、本文のファイル名ではない（値が @パスのときだけファイル）。
if [ "$#" -eq 0 ]; then exec gh; fi
CHECK="$(cd "$(dirname "$0")" && pwd)/check-private-identifiers.sh"
TEXT="$(mktemp -t gh-guarded-text)"
TEMPS=()
STDIN_BODY=""
# 一時ファイルは配列で持ち、引用付きで消す（TMPDIR に空白があっても別のファイルを消さない）。
# bash 3.2 は set -u で空の配列の展開を嫌うので ${a[@]+...} の形にする
cleanup() { rm -f "$TEXT"; local f; for f in ${TEMPS[@]+"${TEMPS[@]}"}; do rm -f "$f"; done; return 0; }
trap cleanup EXIT
printf '%s\n' "$@" > "$TEXT"
SUB="$1"
refuse() { echo "gh-guarded: $*" >&2; exit 1; }

# 本文の指定 $1 を検査できる通常のファイルにし、そのパスを INPUT に入れる（$(...) で呼ばない —
# サブシェルでは一時ファイルの記録が残らない）。
resolve_input() {
  local src="$1" tmp
  if [ "$src" = "-" ]; then
    if [ -z "$STDIN_BODY" ]; then
      STDIN_BODY="$(mktemp -t gh-guarded-body)"; TEMPS+=("$STDIN_BODY")
      cat > "$STDIN_BODY"
    fi
    INPUT="$STDIN_BODY"
  elif [ -f "$src" ]; then
    INPUT="$src"
  elif [ -e "$src" ]; then                         # パイプ・/dev/fd など: 中身を受けてから渡す
    tmp="$(mktemp -t gh-guarded-body)"; TEMPS+=("$tmp")
    cat "$src" > "$tmp" || refuse "cannot read body input: $src"
    INPUT="$tmp"
  else
    refuse "body input not found: $src"
  fi
  cat "$INPUT" >> "$TEXT"; echo >> "$TEXT"       # 本文どうしをつなげない（^ $ の検査語のため）
}

# gh api の -F / --field の「キー=値」。gh と同じく、最初の "=" の直後が "@" のときだけ値をファイルとして
# 読む（値の途中の "=@" はそのままの文字列）。結果を FIELD に入れる
expand_field() {
  local key="${1%%=*}" value="${1#*=}"
  FIELD="$1"
  case "$1" in *=*) ;; *) return 0 ;; esac
  case "$value" in
    @*) resolve_input "${value#@}"; FIELD="$key=@$INPUT" ;;
  esac
}

ARGS=()
expect=""                                          # 次の引数の扱い: input（本文のファイル）/ field（gh api の -F）
for a in "$@"; do
  case "$expect" in
    input)
      expect=""
      resolve_input "$a"; a="$INPUT" ;;
    field)                                         # gh api -F key=value: 値が @パスのときだけファイル
      expect=""
      expand_field "$a"; a="$FIELD" ;;
    *)
      case "$a" in
        --body-file|--notes-file|--input) expect=input ;;
        -F) if [ "$SUB" = "api" ]; then expect=field; else expect=input; fi ;;
        --field) expect=field ;;
        --body-file=*|--notes-file=*|--input=*)
          resolve_input "${a#*=}"; a="${a%%=*}=$INPUT" ;;
        --field=*)                                 # --field=key=value
          expand_field "${a#--field=}"; a="--field=$FIELD" ;;
        *)
          [ -f "$a" ] && { cat "$a" >> "$TEXT"; echo >> "$TEXT"; } ;;    # gist のファイルなど（-f/--raw-field の値はそのまま）
      esac ;;
  esac
  ARGS+=("$a")
done
[ -z "$expect" ] || refuse "missing value for the last option"
"$CHECK" text "$TEXT" || refuse "refusing to post: gh $1 ${2:-}"
# exec で置き換えると後片付け（trap）が走らないので、gh を呼んでから終了コードを返す
rc=0
gh "${ARGS[@]}" || rc=$?
exit "$rc"
