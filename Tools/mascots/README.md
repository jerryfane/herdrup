# Agent mascots

The twelve bundled agent mascots (herdrup#538, the owner-approved "Pebbles" v3 set):
Herdy (the default, from the app icon), Bot, Blip, Tri, Squib, Zag, Cub, Dome, Pip,
Prism, Nib and Drop.

- `mascots.svg` is the source of truth: one `<symbol id="p-<id>" viewBox="0 0 64 64">`
  per mascot, extracted verbatim from the approved proposal page.
- `generate-mascots.py` writes each symbol to
  `App/Assets.xcassets/Mascot-<id>.imageset/mascot.svg`, kept as a vector
  (`preserves-vector-representation`) so it stays crisp from 26 pt to 72 pt.

```sh
# New art: refresh the sprite from an approved proposal page, then regenerate
python3 Tools/mascots/generate-mascots.py --from-html path/to/APPROVED-mascots.html
# Regenerate the image sets from the committed sprite
python3 Tools/mascots/generate-mascots.py
# Check that the committed image sets match the sprite
python3 Tools/mascots/generate-mascots.py --check
```

Adding or removing a mascot also means updating `MASCOTS` in the script and
`AgentMascot` in `Sources/HerdrKit/AgentAvatarDescriptor.swift`. The server accepts
any `^[a-z0-9-]{1,32}$` id; an app build that doesn't know an id draws the name's
generated circle instead.
