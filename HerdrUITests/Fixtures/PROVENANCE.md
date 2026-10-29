# Vendored fixtures

## desktop-reference-agents.json

A byte-for-byte copy of Herdrup Desktop's fake herdr roster. It is an `agent.list` result with the top-level keys `type` and `agents`.

- Repository: [jerryfane/herdrup-desktop](https://github.com/jerryfane/herdrup-desktop)
- Path: `cmd/fakeherdr/agents.json`
- Commit: `0b5111ed47fb2325f6caf4a383758209c6d6c9f6`
- sha256: `f912df090a009597e326cc7df873addc242be2400e8645f5c654c2b168a081e2`

`DesktopReferenceShots` checks the sha256 before every launch. It passes the bytes to the app in `HERDR_DESKTOPREF_AGENT_LIST`, and the `desktopref` screenshot mock serves them unchanged as the `result` of `agent.list`. The references under `design/reference/agent-list/` are drawn from this file. Do not edit it here: update it from the desktop repository, then update the commit, the sha256 (here, in the test and in the manifest), and the references.

## desktop-reference-<state>.json and desktop-reference-avatar.png

Written here, for the served reference states, and copied byte for byte to Herdrup Desktop so its fake herdr serves the same data (`/root/fleet-tools/state/herdrup-desk/reference-states-fixtures/`). Each file is one JSON object: `state`, then every answer the state gives, keyed by what it answers.

- `ping`, `agent.list`, `agent.groups.get`: that method's `result`.
- `agent.avatar.get`: the `result` for each picture, keyed by its sha256 (the request's `params.sha256`).
- `herdr session list --json`: that command's output on the machine.
- `agent.list in session`: the `agent.list` result of each other running session, keyed by session name (`herdr --session <name>`).

A method a state has no key for is refused as `unknown_method`.

| File | sha256 |
|---|---|
| `desktop-reference-folders.json` | `3caf0afb562d97779d07a4080dd4a92d1be414f308370baea9de2e5e226823b0` |
| `desktop-reference-avatars.json` | `c4db4b975cd231e89d95c711048089a5055769ef05c3386f7038472a2aa28514` |
| `desktop-reference-sessions.json` | `a7e1acbcb2de2be2d29309e7976e6d7bab2ac89a7123e8804a6d40ad3018cdd5` |
| `desktop-reference-federated.json` | `cbad3a2d6115309845b70d9d7a1db6793c356bb943dc4c754b7727b74405ebcf` |
| `desktop-reference-needs-you.json` | `851d7f7e03f8b31f8a932aa24f83cecbe0677184ed4afc2aacef6ff8f903df2e` |
| `desktop-reference-avatar.png` | `e4d4139d5914062cd06d5b6cbd8ade1d5fddf83c20ee575d4d83b8d81de38a4a` |

`desktop-reference-avatar.png` is atlas's uploaded picture in the avatars state: a 256×256, 16-colour PNG of 559 bytes (a sunset over water). `desktop-reference-avatars.json` carries the same bytes as base64 under that sha256, and `DesktopReferenceShots` checks both before the launch. Like the roster above, change these only together with the sha256 here, in the test and in the manifest, and the references.
