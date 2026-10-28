# Design tokens

`tokens.json` is the source of truth for the colours and fonts of both Herdrup apps:

- the iOS/iPad/Mac app in this repo, and
- Herdrup Desktop ([jerryfane/herdrup-desktop](https://github.com/jerryfane/herdrup-desktop)).

Neither app keeps its own copy of a colour or a font name. To change one, change it here.

## Changing a token

1. Edit `design/tokens.json`.
2. Run the generator (Python 3, no dependencies):

   ```sh
   python3 Tools/tokens/generate.py
   ```

   It rewrites `App/Generated/DesignTokens.swift`, the `enum DesignTokens` that
   `Palette`, `ChatPalette`, `AgentGroup.color`, `AgentIdentity` and `Typography` read.
   Never edit the generated file by hand.
3. Commit both files together.

CI reruns the generator and fails if `App/Generated` differs from what is committed
(the "Symbol font is the upstream subset" job, step "Verify the design tokens are
generated"). `HerdrFontTests/DesignTokensTests` pins every app colour and font name to its
value, so a deliberate change updates that test too.

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
| `type` | named type roles; `font` names a key of `font`, `weight` one of its faces |
