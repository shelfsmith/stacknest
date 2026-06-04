#!/usr/bin/env bash
# Phase 2.5i fixtures: 1page.pdf + 5pages.pdf for PDFBookContent tests.
# Idempotent: re-running produces byte-identical files (SOURCE_DATE_EPOCH=0
# pins reportlab timestamps and invariant=1 freezes the document ID).
set -euo pipefail

# Dependency check
python3 -c "import reportlab" 2>/dev/null || {
  echo "reportlab not installed. Run: .venv/bin/pip install reportlab" >&2
  exit 1
}

DEST="$(cd "$(dirname "$0")/.." && pwd)/pdf"
BUNDLE_DEST="$(cd "$(dirname "$0")/../.." && pwd)/AppCoreTests/PDFFixtures"
mkdir -p "$DEST" "$BUNDLE_DEST"

SOURCE_DATE_EPOCH=0 python3 - "$DEST" <<'PY'
import sys, os
from reportlab.pdfgen import canvas

dest = sys.argv[1]
for (name, n) in [("1page.pdf", 1), ("5pages.pdf", 5)]:
    path = os.path.join(dest, name)
    c = canvas.Canvas(path)
    c._doc.invariant = 1
    for i in range(n):
        c.setFont("Helvetica", 36)
        c.drawString(72, 720, f"Page {i+1}")
        c.showPage()
    c.save()
    print(f"wrote {path}")
PY

# Mirror to the AppCoreTests bundle copy so the two stay in sync.
cp "$DEST"/*.pdf "$BUNDLE_DEST/"
echo "mirrored to $BUNDLE_DEST"
