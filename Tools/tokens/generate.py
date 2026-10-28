#!/usr/bin/env python3
"""Generate App/Generated/DesignTokens.swift from design/tokens.json.

design/tokens.json is the source of truth for the app's colours, fonts and shared layout
numbers, shared with Herdrup Desktop (see design/README.md). This writes it out as
`enum DesignTokens`, which Palette, ChatPalette, AgentGroup, AgentIdentity, Typography and
the agent list read. Edit the JSON, run `python3 Tools/tokens/generate.py`, commit both;
CI reruns this and fails on a diff.

Values:
  "#RRGGBB"        a colour, written as a UInt32 (0xRRGGBB)
  "{a.b.c}"        a reference to the token at that path, written as its resolved value
  other strings    literals (font families, PostScript names, file paths)
  numbers, bools   Int / Double / Bool
  arrays           all colours ([UInt32]) or all strings ([String])
  null             absent (color.light: the app is dark-only); nothing is written
Keys starting with "_" and "schema_version" are not tokens.

Layout groups (points):
  space.*, radius.*, size.*   numbers, written as CGFloat
  text.<role>                 a text role: `font` names a key of font, `size` and the
                              optional `tracking` are CGFloat, `weight` is a CSS weight
                              written as a SwiftUI Font.Weight; other keys as above

Python 3, stdlib only.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "design" / "tokens.json"
OUTPUT = ROOT / "App" / "Generated" / "DesignTokens.swift"

SCHEMA_VERSION = 1
COLOUR = re.compile(r"^#[0-9A-Fa-f]{6}$")
REFERENCE = re.compile(r"^\{([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*)\}$")
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# Font face keys are CSS weights; Swift names them.
WEIGHT_NAMES = {
    "100": "Thin", "200": "ExtraLight", "300": "Light", "400": "Regular", "500": "Medium",
    "600": "Semibold", "700": "Bold", "800": "ExtraBold", "900": "Black",
}
# A text role's CSS weight, as the SwiftUI Font.Weight of the same rank.
FONT_WEIGHTS = {
    100: ".ultraLight", 200: ".thin", 300: ".light", 400: ".regular", 500: ".medium",
    600: ".semibold", 700: ".bold", 800: ".heavy", 900: ".black",
}
# Groups whose numbers are layout points (CGFloat).
LAYOUT_GROUPS = {"space", "radius", "size"}
# Keys of a text role written as CGFloat.
TEXT_POINTS = {"size", "tracking"}
# Group names Swift cannot declare as a nested type (`X.Type` is the metatype).
TYPE_RENAMES = {"Type": "TypeRole"}
SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
    "import", "init", "inout", "internal", "let", "open", "operator", "private",
    "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
    "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do",
    "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
    "switch", "where", "while", "as", "false", "is", "nil", "self", "Self", "super",
    "throws", "true", "try", "Any",
}


class TokenError(Exception):
    pass


def is_token_key(key):
    return not key.startswith("_") and key != "schema_version"


def lookup(tokens, path, where):
    node = tokens
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node or not is_token_key(part):
            raise TokenError(f"{where}: reference {{{path}}} names no token")
        node = node[part]
    return node


def resolve(tokens, value, where, seen=()):
    """The value with every reference followed to a literal. Cycles and dangling
    references are errors; a reference must land on a leaf, not a group or null."""
    if isinstance(value, str):
        match = REFERENCE.match(value)
        if match:
            path = match.group(1)
            if path in seen:
                chain = " -> ".join([*seen, path])
                raise TokenError(f"{where}: reference cycle {chain}")
            target = lookup(tokens, path, where)
            if target is None or isinstance(target, dict):
                raise TokenError(f"{where}: reference {{{path}}} is not a single token")
            return resolve(tokens, target, where, (*seen, path))
        if "{" in value or "}" in value:
            raise TokenError(f"{where}: {value!r} is neither a reference nor a literal")
        if value.startswith("#") and not COLOUR.match(value):
            raise TokenError(f"{where}: {value!r} is not a #RRGGBB colour")
        return value
    if isinstance(value, list):
        return [resolve(tokens, item, f"{where}[{i}]", seen) for i, item in enumerate(value)]
    if isinstance(value, bool) or isinstance(value, (int, float)):
        return value
    raise TokenError(f"{where}: unsupported value {value!r}")


def type_name(key, where):
    if key in WEIGHT_NAMES:
        return WEIGHT_NAMES[key]
    if not IDENTIFIER.match(key):
        raise TokenError(f"{where}: {key!r} cannot name a Swift type")
    name = key[0].upper() + key[1:]
    return TYPE_RENAMES.get(name, name)


def member_name(key, where):
    if not IDENTIFIER.match(key):
        raise TokenError(f"{where}: {key!r} cannot name a Swift member")
    return f"`{key}`" if key in SWIFT_KEYWORDS else key


def swift_literal(value, where):
    """(Swift type, Swift literal) for a resolved value."""
    if isinstance(value, bool):
        return "Bool", "true" if value else "false"
    if isinstance(value, int):
        return "Int", str(value)
    if isinstance(value, float):
        return "Double", repr(value)
    if isinstance(value, str):
        if COLOUR.match(value):
            return "UInt32", "0x" + value[1:].upper()
        return "String", json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        items = [swift_literal(item, f"{where}[{i}]") for i, item in enumerate(value)]
        kinds = {kind for kind, _ in items}
        if len(kinds) != 1:
            raise TokenError(f"{where}: an array must hold one kind of value, got {sorted(kinds)}")
        (kind,) = kinds
        return f"[{kind}]", "[" + ", ".join(literal for _, literal in items) + "]"
    raise TokenError(f"{where}: unsupported value {value!r}")


def font_families(tokens):
    return {k: v for k, v in tokens.get("font", {}).items() if is_token_key(k)}


def derived_type_role(tokens, role, where):
    """A type role names a font and a weight; the PostScript name they pick is what
    Swift needs, so it is written alongside."""
    font = resolve(tokens, role.get("font"), f"{where}.font")
    weight = resolve(tokens, role.get("weight"), f"{where}.weight")
    families = font_families(tokens)
    if font not in families:
        raise TokenError(f"{where}.font: {font!r} is not a key of font")
    face = families[font].get("faces", {}).get(str(weight))
    if face is None:
        raise TokenError(f"{where}.weight: font.{font} has no {weight} face")
    return [("postscript", face["postscript"], f"font.{font}.faces.{weight}.postscript")]


def check_text_role(tokens, role, where):
    """A text role names a font and gives a size and a CSS weight. A font with bundled
    faces must have that weight; the platform font ("system") draws every weight."""
    for key in ("font", "size", "weight"):
        if key not in role:
            raise TokenError(f"{where}: a text role needs {key}")
    font = resolve(tokens, role["font"], f"{where}.font")
    families = font_families(tokens)
    if font not in families:
        raise TokenError(f"{where}.font: {font!r} is not a key of font")
    weight = resolve(tokens, role["weight"], f"{where}.weight")
    faces = families[font].get("faces")
    if faces is not None and str(weight) not in faces:
        raise TokenError(f"{where}.weight: font.{font} has no {weight} face")


def points_literal(value, where):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TokenError(f"{where}: {value!r} is not a number of points")
    return "CGFloat", str(value) if isinstance(value, int) else repr(value)


def leaf_literal(path, key, value, where):
    """(Swift type, Swift literal, trailing comment) for a resolved leaf at path.key."""
    if path and path[0] in LAYOUT_GROUPS:
        return (*points_literal(value, where), None)
    if len(path) == 2 and path[0] == "text":
        if key in TEXT_POINTS:
            return (*points_literal(value, where), None)
        if key == "weight":
            if isinstance(value, bool) or value not in FONT_WEIGHTS:
                raise TokenError(f"{where}: {value!r} is not a CSS weight (100-900)")
            return "SwiftUI.Font.Weight", FONT_WEIGHTS[value], str(value)
    return (*swift_literal(value, where), None)


def emit_group(tokens, node, path, indent, out):
    pad = "    " * indent
    for key, value in node.items():
        if not is_token_key(key) or value is None:
            continue
        where = ".".join([*path, key])
        if isinstance(value, dict):
            if path == ["text"]:
                check_text_role(tokens, value, where)
            out.append(f"{pad}enum {type_name(key, where)} {{")
            emit_group(tokens, value, [*path, key], indent + 1, out)
            if path == ["type"]:
                for name, literal, source in derived_type_role(tokens, value, where):
                    kind, swift = swift_literal(literal, where)
                    out.append(f"{pad}    /// Derived: {source}.")
                    out.append(f"{pad}    static let {member_name(name, where)}: {kind} = {swift}")
            out.append(f"{pad}}}")
            continue
        resolved = resolve(tokens, value, where)
        kind, swift, note = leaf_literal(path, key, resolved, where)
        line = f"{pad}static let {member_name(key, where)}: {kind} = {swift}"
        if isinstance(value, str) and REFERENCE.match(value):
            line += f"  // {value}"
        elif note:
            line += f"  // {note}"
        out.append(line)


def generate(tokens):
    if tokens.get("schema_version") != SCHEMA_VERSION:
        raise TokenError(f"schema_version must be {SCHEMA_VERSION}")
    out = [
        "// GENERATED by Tools/tokens/generate.py from design/tokens.json. DO NOT EDIT.",
        "// Edit design/tokens.json, run `python3 Tools/tokens/generate.py`, commit both.",
        "// CI regenerates this file and fails if it differs from the committed copy.",
        "",
        "import SwiftUI",
        "",
        "/// The shared design tokens (design/tokens.json), the source of truth for this app's",
        "/// colours, fonts and shared layout numbers and for Herdrup Desktop's. Colours are",
        "/// 0xRRGGBB; space, radius, size and text sizes are points (text sizes at scale 1).",
        "enum DesignTokens {",
    ]
    emit_group(tokens, tokens, [], 1, out)
    out.append("}")
    return "\n".join(out) + "\n"


def main():
    try:
        tokens = json.loads(SOURCE.read_text(encoding="utf-8"))
        swift = generate(tokens)
    except (TokenError, json.JSONDecodeError) as error:
        print(f"{SOURCE.relative_to(ROOT)}: {error}", file=sys.stderr)
        return 1
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != swift:
        OUTPUT.write_text(swift, encoding="utf-8")
        print(f"wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
