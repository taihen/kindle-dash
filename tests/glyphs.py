#!/usr/bin/env python3
"""Every glyph in the weather icons must exist in the chosen font.

A missing code point renders as a .notdef box - a hollow rectangle on the panel
that looks like a design element until you know better. This caught U+26C5 (the
"sun behind cloud" emoji) missing from DejaVu, which shipped for an afternoon.

    python3 tests/glyphs.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import render  # noqa: E402
from PIL import ImageFont  # noqa: E402


def bitmap(font, ch):
    mask = font.getmask(ch, mode="L")
    return mask.size, bytes(mask)


def main() -> int:
    font = ImageFont.truetype(str(Path(render.FONT_DIR) / "DejaVuSans.ttf"), 40)
    missing_ref = bitmap(font, "\uffff")
    bad = []
    for condition, (glyph, _label) in sorted(render.CONDITIONS.items()):
        for ch in glyph:
            if bitmap(font, ch) == missing_ref:
                bad.append((condition, f"U+{ord(ch):04X}"))
    print(f"font dir: {render.FONT_DIR}")
    print(f"conditions checked: {len(render.CONDITIONS)}")
    if bad:
        for condition, code in bad:
            print(f"MISSING  {condition}: {code}")
        return 1
    print("all icon glyphs present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
