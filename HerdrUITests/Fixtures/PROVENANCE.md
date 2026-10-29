# Vendored fixtures

## desktop-reference-agents.json

A byte-for-byte copy of Herdrup Desktop's fake herdr roster. It is an `agent.list` result with the top-level keys `type` and `agents`.

- Repository: [jerryfane/herdrup-desktop](https://github.com/jerryfane/herdrup-desktop)
- Path: `cmd/fakeherdr/agents.json`
- Commit: `0b5111ed47fb2325f6caf4a383758209c6d6c9f6`
- sha256: `f912df090a009597e326cc7df873addc242be2400e8645f5c654c2b168a081e2`

`DesktopReferenceShots` checks the sha256 before every launch. It passes the bytes to the app in `HERDR_DESKTOPREF_AGENT_LIST`, and the `desktopref` screenshot mock serves them unchanged as the `result` of `agent.list`. The references under `design/reference/agent-list/` are drawn from this file. Do not edit it here: update it from the desktop repository, then update the commit, the sha256 (here, in the test and in the manifest), and the references.
