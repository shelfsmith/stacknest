#!/bin/bash
# Tests/Fixtures/rar5-*.rar を再生成する。
#
# なぜ検体をコミットするのか: `rar` は proprietary で GitHub Actions のランナーに無い。
# 実行時に生成していた頃はテストが CI でスキップされ、RAR 経路が完全に無検証だった。
# 検体は自作の内容なのでライセンス上の問題は無い。
#
# 実行には `rar` が要る（開発機のみ・brew install rar 等）。CI では実行しない。
set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"
WORK="$SCRIPT_DIR/_rar_work"
RAR="$(command -v rar || true)"
if [ -z "$RAR" ]; then
  echo "error: rar が見つかりません。検体の再生成には rar が必要です。" >&2
  exit 1
fi

rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

# ① ディレクトリエントリを含む RAR5。
#    RAR はディレクトリでも名前に末尾 "/" を付けない（ZIP と違う）。
#    この検体は「名前だけでディレクトリ判定するとファイル扱いになり、
#    データを読もうとして負値が返り、破損と誤判定される」経路を踏む。
mkdir -p somedir
python3 -c "
import struct, zlib
def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
png=(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))
     +chunk(b'IDAT',zlib.compress(b'\x00\xff\x00\x00'))+chunk(b'IEND',b''))
open('somedir/1.png','wb').write(png)
open('top.png','wb').write(png)
"
"$RAR" a -r -ma5 -idq "$SCRIPT_DIR/rar5-with-directory.rar" . >/dev/null

# ② 圧縮ストリームを壊した RAR5。
#    圧縮(-m5)させたうえで中身のバイトを反転する。ヘッダは無傷なので、
#    ヘッダ走査だけの実装は「正常」と判定する ―― CRC 検証だけが検出できる。
cd "$WORK"; rm -rf ./*;
python3 -c "open('big.txt','w').write('A'*200000)"
"$RAR" a -m5 -ma5 -idq "$SCRIPT_DIR/rar5-corrupted-entry.rar" big.txt >/dev/null
python3 - "$SCRIPT_DIR/rar5-corrupted-entry.rar" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p,'rb').read())
# ヘッダを避けて後半のデータ領域を壊す
for i in range(len(b)//2, len(b)//2 + 32):
    b[i] ^= 0xFF
open(p,'wb').write(bytes(b))
PY

rm -rf "$WORK"
echo "生成しました:"
ls -la "$SCRIPT_DIR"/rar5-*.rar
