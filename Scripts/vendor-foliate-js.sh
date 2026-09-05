#!/usr/bin/env bash
# foliate-js（MIT）の EPUB に必要なファイルと、依存 @zip.js/zip.js（BSD-3-Clause）を固定版で vendoring する。
# 再実行すると同じ内容になる（コミット・版を固定）。vendor の中身は手で編集しない。
set -euo pipefail
COMMIT=78914aef4466eb960965702401634c2cb348e9b1
ZIPJS_VERSION=2.11.1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/LibraryServer/Resources/web/vendor/foliate-js"
mkdir -p "$DEST/vendor"
for f in view.js epub.js epubcfi.js paginator.js fixed-layout.js progress.js overlayer.js text-walker.js LICENSE; do
  curl -fsSL "https://raw.githubusercontent.com/johnfactotum/foliate-js/$COMMIT/$f" -o "$DEST/$f"
done
# zip.js: npm の tarball から ESM 単体ビルド index.min.js を取る（foliate の rollup 出力と同じ公開 API）
TMP="$(mktemp -d)"
curl -fsSL "https://registry.npmjs.org/@zip.js/zip.js/-/zip.js-$ZIPJS_VERSION.tgz" | tar -xz -C "$TMP"
cp "$TMP/package/index.min.js" "$DEST/vendor/zip.js"
cp "$TMP/package/LICENSE" "$DEST/vendor/LICENSE-zip.js"
rm -r "$TMP"
{
  echo "# vendored versions"
  echo
  echo "- foliate-js: https://github.com/johnfactotum/foliate-js @ $COMMIT (MIT) — files: view epub epubcfi paginator fixed-layout progress overlayer text-walker"
  echo "- @zip.js/zip.js: $ZIPJS_VERSION (BSD-3-Clause) — index.min.js as vendor/zip.js"
  echo
  echo "Regenerate: Scripts/vendor-foliate-js.sh"
} > "$DEST/VERSIONS.md"
echo "vendored into $DEST"
