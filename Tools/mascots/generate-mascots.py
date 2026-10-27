#!/usr/bin/env python3
"""Generate the agent mascot image sets from the approved art (herdrup#538).

The source of truth is `mascots.svg` beside this script: one SVG sprite holding the
twelve approved "Pebbles" v3 mascots as <symbol id="p-<id>" viewBox="0 0 64 64">.
Each symbol becomes a standalone 64x64 SVG in
`App/Assets.xcassets/Mascot-<id>.imageset/mascot.svg`, kept as a vector
(`preserves-vector-representation`) so it renders crisply at every size the app
draws an agent (26 pt Gram stacks up to the 72 pt guest accept card).

    # Refresh the sprite from a new approved proposal page, then regenerate:
    python3 Tools/mascots/generate-mascots.py --from-html APPROVED-mascots.html
    # Regenerate the image sets from the committed sprite:
    python3 Tools/mascots/generate-mascots.py
    # Fail if the committed image sets differ from what the sprite generates:
    python3 Tools/mascots/generate-mascots.py --check

The art is extracted verbatim, never redrawn. Standard library only.
"""

import argparse
import json
import pathlib
import re
import sys

# The bundled set, in picker order. Herdy (from the app icon) is the default for an
# agent without a choice. Keep in sync with `AgentMascot` (Sources/HerdrKit/AgentAvatarDescriptor.swift).
MASCOTS = ["herdy", "bot", "blip", "tri", "squib", "zag", "cub", "dome", "pip", "prism", "nib", "drop"]

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
SPRITE = HERE / "mascots.svg"
ASSETS = REPO / "App" / "Assets.xcassets"

SYMBOL = re.compile(r'<symbol id="p-([a-z0-9-]+)" viewBox="0 0 64 64">(.*?)</symbol>', re.S)

CONTENTS = {
    "images": [{"filename": "mascot.svg", "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1},
    "properties": {"preserves-vector-representation": True},
}


def symbols(text):
    found = {m.group(1): m.group(2) for m in SYMBOL.finditer(text)}
    missing = [m for m in MASCOTS if m not in found]
    if missing:
        sys.exit(f"missing mascot symbols: {', '.join(missing)}")
    return {m: found[m] for m in MASCOTS}


def sprite_text(art):
    lines = ['<svg xmlns="http://www.w3.org/2000/svg" style="display:none">',
             "<!-- Approved agent mascots, Pebbles v3 (herdrup#538). Generated input for",
             "     Tools/mascots/generate-mascots.py; edit the art here, then regenerate. -->"]
    for name, body in art.items():
        lines.append(f'<symbol id="p-{name}" viewBox="0 0 64 64">{body}</symbol>')
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def standalone(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">'
            f"{body}</svg>\n")


def outputs(art):
    files = {}
    for name, body in art.items():
        folder = ASSETS / f"Mascot-{name}.imageset"
        files[folder / "mascot.svg"] = standalone(body)
        files[folder / "Contents.json"] = json.dumps(CONTENTS, indent=2) + "\n"
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--from-html", type=pathlib.Path,
                        help="approved proposal page; rewrites mascots.svg from its p-<id> symbols")
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if the committed image sets differ from the sprite")
    args = parser.parse_args()

    if args.from_html:
        art = symbols(args.from_html.read_text(encoding="utf-8"))
        SPRITE.write_text(sprite_text(art), encoding="utf-8")
    art = symbols(SPRITE.read_text(encoding="utf-8"))

    stale = []
    for path, text in outputs(art).items():
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current == text:
            continue
        if args.check:
            stale.append(str(path.relative_to(REPO)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    if stale:
        sys.exit("mascot assets differ from Tools/mascots/mascots.svg:\n  " + "\n  ".join(stale))


if __name__ == "__main__":
    main()
