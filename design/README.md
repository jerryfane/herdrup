# Design tokens

`tokens.json` is the source of truth for the colours, fonts and shared layout numbers of
both Herdrup apps:

- the iOS/iPad/Mac app in this repo, and
- Herdrup Desktop ([jerryfane/herdrup-desktop](https://github.com/jerryfane/herdrup-desktop)).

Neither app keeps its own copy of a colour or a font name. To change one, change it here.
Layout numbers are being moved over surface by surface (see [Layout tokens](#layout-tokens)).

## Changing a token

1. Edit `design/tokens.json`.
2. Run the generator (Python 3, no dependencies):

   ```sh
   python3 Tools/tokens/generate.py
   ```

   It rewrites `App/Generated/DesignTokens.swift`, the `enum DesignTokens` that
   `Palette`, `ChatPalette`, `AgentGroup.color`, `AgentIdentity`, `Typography` and the
   agent list read.
   Never edit the generated file by hand.
3. Commit both files together.

CI reruns the generator and fails if `App/Generated` differs from what is committed
(the "Symbol font is the upstream subset" job, step "Verify the design tokens are
generated"). `HerdrFontTests/DesignTokensTests` pins every app colour, font name, layout
number and text role to its value, so a deliberate change updates that test too.

## Herdrup Desktop

The desktop app syncs from a **pinned commit** of this file: it copies `tokens.json` at a
specific herdrup commit and turns token paths into CSS variables
(`color.dark.textDim` -> `--color-text-dim`). A change here reaches the desktop only when
it moves its pin to a commit that has the change.

## Format

- `"#RRGGBB"` is a colour.
- `"{group.path}"` is a reference to another token by its path (`"{status.waiting}"`).
  References resolve to a single token, never a group; dangling references and cycles are
  generator errors. Any other string is a literal (a font family, a PostScript name, a
  file path).
- Numbers and booleans are literal values (`onAccentDimOpacity`, a type role's size).
  Numbers in `space`, `radius`, `size` and in a `text` role's `size`/`tracking` are
  points, written to Swift as `CGFloat`; a `text` role's `weight` is a CSS weight
  (100-900), written as the SwiftUI `Font.Weight` of the same rank.
- `null` means absent: `color.light` is null because the app is dark-only.
- Keys starting with `_` are comments; `schema_version` is the format's version.

Groups:

| Group | What it holds |
| --- | --- |
| `color.dark` | the app's ground, surfaces, rules, text tiers, brand, on-accent white |
| `status` | the four status colours: waiting, died, working, done |
| `group` | each agent-list group's colour, as a reference to a status or text colour |
| `agentGradient` | each agent kind's identity gradient, top-leading first |
| `chat.dark`, `chat.light` | omp's tokyo-night chat colours |
| `font.app`, `font.machine` | family, CSS fallback stack, the 400-700 faces (PostScript name and file under `App/Fonts`), and the OFL licence |
| `font.system` | the platform UI font (`family: "system"`): San Francisco on Apple platforms, with a CSS fallback stack. No faces: the platform draws every weight |
| `type` | named type roles; `font` names a key of `font`, `weight` one of its faces. `type.microLabel` refers to `text.microLabel` |
| `space` | horizontal insets and stack spacings, in points |
| `radius` | corner radii, in points |
| `size` | fixed heights, widths, diameters and stroke widths, in points |
| `text` | text roles: `font` (a key of `font`), `size` and `weight`, optional `tracking` (points), `tabular` (monospaced digits) and `uppercase` |

## Layout tokens

`space`, `radius`, `size` and `text` hold the agent list and sidebar's numbers at
regular width (iPad/Mac), so Herdrup Desktop can match them point for point. Text sizes
are at text scale 1: herdrup multiplies `text.*.size` by `Typography.scale` (0.9-1.4) and
the agent row height by `max(1, scale)`. A number is a token only when it is used in more
than one place or the desktop needs it; one-off numbers stay in code.

Herdrup keeps San Francisco and SF Symbols (owner decision 2026-10-28). `font.system`
expresses that: a `text` role whose `font` is `"system"` is drawn with
`.system(size:weight:)` in herdrup, matched exactly by the desktop on Mac and by the
nearest open font elsewhere.

**What reads them.** The agent list and sidebar read these tokens through
`DesignTokens`: the agent row, folder row and group disclosure row (`HerdrApp.card`,
`disclosureRow`, `AgentFolderRow`), the avatar and its status badge (`AgentAvatar`), the
section top bar, search field, empty state and Terminals header, the archived and terminal
cards, the needs-you pill, the sidebar's tab bar, tab badge and rail, the split view's
sidebar width bounds, and the "Select an agent" placeholder. Every other surface still
carries its own literals: those values are documented here for the desktop but are not
yet wired (for example `radius.group`, the settings group corner, and `size.hairline`
outside the agent list).
