#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"
WORK="$SCRIPT_DIR/_work"
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

# Make a tiny 1x1 red PNG using Python
python3 - <<'PY'
import struct, zlib
def make_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
def png(path):
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    ihdr_chunk = make_chunk(b"IHDR", ihdr)
    raw = b"\x00\xff\x00\x00"
    idat = zlib.compress(raw)
    idat_chunk = make_chunk(b"IDAT", idat)
    iend_chunk = make_chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(sig + ihdr_chunk + idat_chunk + iend_chunk)
png("page01.png")
png("page02.png")
PY

# zip
zip -q "$SCRIPT_DIR/sample_cover.zip" page01.png page02.png

# cbz (= zip)
cp "$SCRIPT_DIR/sample_cover.zip" "$SCRIPT_DIR/sample_cover.cbz"

# cbr — only if rar(1) is installed
if command -v rar >/dev/null 2>&1; then
    rar a -inul "$SCRIPT_DIR/sample_cover.cbr" page01.png page02.png
else
    echo "WARNING: rar(1) not installed; cbr fixture skipped (cbr test will early-return)"
fi

# empty zip — create a zip with no image files (just a placeholder .txt)
mkdir empty
touch empty/.gitkeep
(cd empty && zip -q -r "$SCRIPT_DIR/empty.zip" .gitkeep)

# three-page zip (natural-sort check: p1 < p2 < p10)
python3 - <<'PY'
import struct, zlib
def make_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
def png(path):
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    raw = b"\x00\xff\x00\x00"
    with open(path, "wb") as f:
        f.write(sig + make_chunk(b"IHDR", ihdr) + make_chunk(b"IDAT", zlib.compress(raw)) + make_chunk(b"IEND", b""))
png("p1.png"); png("p2.png"); png("p10.png")
PY
zip -q "$SCRIPT_DIR/three_pages.zip" p1.png p2.png p10.png

# image folder book fixture (committed directly, not generated into a zip)
rm -rf "$SCRIPT_DIR/folder_book"
mkdir -p "$SCRIPT_DIR/folder_book"
cp p1.png "$SCRIPT_DIR/folder_book/page1.png"
cp p2.png "$SCRIPT_DIR/folder_book/page2.png"
cp p10.png "$SCRIPT_DIR/folder_book/page10.png"

# corrupt zip
printf "PK\x03\x04CORRUPTED" > "$SCRIPT_DIR/corrupt.zip"

cd "$SCRIPT_DIR"
rm -rf "$WORK"
echo "Fixtures generated."
