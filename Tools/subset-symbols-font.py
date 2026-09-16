#!/usr/bin/env python3
"""Build `App/Fonts/HerdrupSymbols-Regular.ttf` from the upstream Nerd Fonts artifact.

WHY THIS FONT IS MODIFIED AT ALL, since shipping upstream verbatim is otherwise
the boring and correct choice.

`SymbolsNerdFontMono-Regular.ttf` maps 10624 codepoints, and exactly 14 of them
sit OUTSIDE the private-use area: U+23FB-U+23FE, U+2630, U+2665, U+26A1,
U+276C-U+2771, U+2B58. IBM Plex Mono maps none of them, so the terminal's font
cascade decides who draws them, and the cascade cannot be ordered to get both
classes right:

  * Symbols FIRST wins the 14 away from the system. U+26A1 has
    Emoji_Presentation=Yes, so `⚡` in agent output rendered as a monochrome Nerd
    glyph instead of colour emoji. That shipped, and was the first bug.
  * Symbols AFTER the system fallbacks fixes those 14 and breaks the opposite
    case: Apple Color Emoji still maps the legacy SoftBank private-use block
    U+E001-U+E537, which overlaps 170 of the shipped Nerd codepoints — Seti
    U+E001-E00A, Font Awesome Extension U+E201-E253, Weather Icons U+E301-E34D —
    and it precedes the symbols, so those 170 glyphs disappear behind emoji.

One order cannot satisfy both, because the conflict is in the font's coverage,
not in the ordering. So the coverage is what changes: this script drops every
non-private-use codepoint, leaving a font that can only ever answer for the PUA.
The cascade then puts it FIRST, where it beats Apple Color Emoji's SoftBank
block, and the 14 reach the system because this font no longer claims them.

LICENSING. The OFL permits modification; it restricts RESERVED FONT NAMES. The
output is therefore renamed to "Herdrup Symbols" rather than continuing to
present itself as the upstream artifact, and `App/Fonts/NerdFonts-LICENSE.txt`
records the modification alongside the fourteen icon sets' own terms. No glyph
outlines are altered — only the character map and the name table.

USAGE (from the repository root; needs fonttools, no Xcode):
    python3 -m venv /tmp/fontenv && /tmp/fontenv/bin/pip install fonttools
    /tmp/fontenv/bin/python Tools/subset-symbols-font.py <upstream.ttf>

`--check` re-derives the subset and verifies the committed font matches what the
upstream input produces, without writing anything.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont

REPO = Path(__file__).resolve().parent.parent
OUTPUT = REPO / "App/Fonts/HerdrupSymbols-Regular.ttf"

FAMILY = "Herdrup Symbols"
POSTSCRIPT = "HerdrupSymbols"

# Private-use: BMP, plus the two supplementary planes. Nothing else survives.
PRIVATE_USE_RANGES = ((0xE000, 0xF8FF), (0xF0000, 0xFFFFD), (0x100000, 0x10FFFD))


def is_private_use(codepoint: int) -> bool:
    return any(low <= codepoint <= high for low, high in PRIVATE_USE_RANGES)


def mapped_codepoints(font: TTFont) -> set[int]:
    return {cp for table in font["cmap"].tables for cp in table.cmap}


def rename(font: TTFont) -> None:
    """Retitle the modified font so it does not pose as the upstream release."""
    name = font["name"]
    for record in list(name.names):
        # 1/2 family+subfamily, 3 unique id, 4 full name, 6 PostScript name,
        # 16/17 typographic family+subfamily.
        if record.nameID in (1, 16):
            name.setName(FAMILY, record.nameID, record.platformID,
                         record.platEncID, record.langID)
        elif record.nameID == 4:
            name.setName(f"{FAMILY} Regular", record.nameID, record.platformID,
                         record.platEncID, record.langID)
        elif record.nameID == 6:
            name.setName(POSTSCRIPT, record.nameID, record.platformID,
                         record.platEncID, record.langID)
        elif record.nameID == 3:
            name.setName(f"{POSTSCRIPT};herdrup-pua-subset", record.nameID,
                         record.platformID, record.platEncID, record.langID)


def build(source: Path) -> bytes:
    font = TTFont(source)
    keep = {cp for cp in mapped_codepoints(font) if is_private_use(cp)}
    dropped = mapped_codepoints(font) - keep
    if not keep:
        sys.exit("refusing to write: the subset would contain no glyphs")

    # The upstream head timestamps are carried over verbatim. fontTools stamps
    # `head.modified` with the current time on save, which makes every run produce
    # different bytes — and a reproducibility check that cannot reproduce is worse than
    # none, because it fails on the honest file and teaches everyone to ignore it.
    created, modified = font["head"].created, font["head"].modified

    options = Options()
    options.glyph_names = True
    options.recalc_bounds = True
    options.drop_tables = []
    options.notdef_outline = True
    subsetter = Subsetter(options=options)
    subsetter.populate(unicodes=keep)
    subsetter.subset(font)
    rename(font)
    # Pinning the values is not enough: `save` recalculates `head.modified` from the
    # clock unless this is off, which is what made two runs seconds apart differ.
    font.recalcTimestamp = False
    font["head"].created, font["head"].modified = created, modified

    out = OUTPUT.parent / (OUTPUT.name + ".tmp")
    font.save(out)
    data = out.read_bytes()
    out.unlink()
    print(f"kept {len(keep)} private-use codepoints; dropped {len(dropped)}: "
          + ", ".join(f"U+{cp:04X}" for cp in sorted(dropped)))
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="upstream SymbolsNerdFontMono-Regular.ttf")
    parser.add_argument("--check", action="store_true",
                        help="verify the committed font instead of writing it")
    args = parser.parse_args()

    data = build(args.source)
    digest = hashlib.sha256(data).hexdigest()

    if args.check:
        if not OUTPUT.exists():
            sys.exit(f"{OUTPUT} is missing")
        committed = hashlib.sha256(OUTPUT.read_bytes()).hexdigest()
        if committed != digest:
            sys.exit(f"{OUTPUT} does not match the subset of {args.source}\n"
                     f"  committed {committed}\n  rebuilt   {digest}")
        print(f"{OUTPUT.name} matches the subset of {args.source.name} ({digest[:16]})")
        return

    OUTPUT.write_bytes(data)
    print(f"wrote {OUTPUT.relative_to(REPO)} ({len(data)} bytes, sha256 {digest[:16]})")


if __name__ == "__main__":
    main()
