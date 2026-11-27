#!/bin/sh
# Render the demo panel and assert the output is what eips needs: a 600x800
# 8-bit greyscale PNG. Catches layout crashes and accidental mode changes
# without needing Home Assistant.
#
#   sh tests/smoke.sh
set -eu
cd "$(dirname "$0")/.."

PY=${PY:-python3}
out=$(mktemp -u).png

"$PY" render.py --demo --config=config.example.toml "$out"
"$PY" - "$out" <<'PY'
import sys
from PIL import Image

im = Image.open(sys.argv[1])
assert im.size == (600, 800), f"expected 600x800, got {im.size}"
assert im.mode == "L", f"expected 8-bit greyscale, got {im.mode}"
lo, hi = im.getextrema()
assert hi - lo > 100, f"frame looks blank (extrema {lo}..{hi})"
print(f"ok: 600x800 greyscale, {sys.argv[1]} ({lo}..{hi})")
PY

rm -f "$out"
