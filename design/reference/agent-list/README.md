# Agent list references for Herdrup Desktop

These are pixel-exact screenshots of herdrup's Agents home on iPad, in landscape, in the regular-width `NavigationSplitView` that the Mac "Designed for iPad" app also uses. Herdrup Desktop ([jerryfane/herdrup-desktop#16](https://github.com/jerryfane/herdrup-desktop/issues/16)) must match them pixel for pixel. `../MAC-DIFFERENCES.md` lists where the Mac app differs from these iPad pictures.

`manifest.json` records, for every PNG: the device, size in points, scale, appearance, Dynamic Type size, status-bar height and override, mock clock, herdrup commit, fixture sha256, and the PNG's own sha256.

## What is in a picture

- **Data.** Herdrup Desktop's fake herdr roster, `cmd/fakeherdr/agents.json` at `0b5111ed47fb2325f6caf4a383758209c6d6c9f6` (sha256 `f912df09…a081e2`). It is vendored as `HerdrUITests/Fixtures/desktop-reference-agents.json` and served unchanged as the `agent.list` result by the DEBUG screenshot mock `HERDR_SCREENSHOT_MOCK=desktopref` (`App/DesktopReferenceMock.swift`).
- **Capabilities.** `ping` advertises what a current herdr fork does (protocol 22), except `agent_groups`. The roster therefore shows no folders or stars, which matches the fixture: it defines no groups. `accounts.list` and `gram.list` answer empty, so no account lines and no Gram badge.
- **States** (`ref-<device>-<state>.png`):
  - `loading`: `agent.list` never answers. The sidebar spinner is frozen on its first frame. Freezing the window's layers also stops the detail column's glyph field before its first resting picture arrives, so the detail column is plain ground behind "Select an agent".
  - `empty`: `agent.list` answers with no agents ("no agents").
  - `populated`: the fixture as the roster first draws it. *Needs you* comes first (api-review blocked, docs waiting on a menu). Then *unrecognised*: studio/render, unreachable, with the offline badge. Then *working* (web, infra). Last come the closed "Idle 2" and "Archived 1" rows. *Stopped* cannot appear: it needs a pane the daemon no longer lists as live, and agent.list alone never says that. These sections have no headers (#352).
  - `idle-expanded`: Idle open (release done, notes idle).
  - `archived-expanded`: Archived open (old-spike).
  - `all-expanded`: both open. On the 11-inch the list runs past the bottom, as it would in the app.
- **Devices.** `ipad-pro-13` is the iPad Pro 13-inch at 1376×1032 pt. `ipad-11` is an 1180×820 pt iPad (iPad Air 11-inch, or the base iPad (A16) when the runner lacks it). Both are @2x, landscape and full screen.
- **Held still.** Dark appearance and the default Dynamic Type size (Large). UIKit and SwiftUI animations are off, and the working ring is drawn at rest. The empty detail column's glyph field is drawn once from a fixed seed (SplitMix64 `0x4845524452555031`, `FieldDice` in `App/SelectAgentField.swift`), with no lens, twinkle or typing. The roster's clock is pinned to `2026-10-28T09:41:00Z` (`HERDR_MOCK_NOW`). That clock is behind the only relative time the list draws: a row's time in its state (`compactTimeInState` in `card`). The fixture has no `status_since_unix_ms`, so no age is drawn. The status bar is overridden to 9:41, full charged battery, three Wi-Fi bars and no cellular, and is 32 pt tall. simctl on this image accepts only a plain time, so the date beside it is the runner's real date ("Wed Oct 28" in these). A capture is kept only after three screenshots 0.5 s apart are byte-identical.

## Regenerating

1. Run the focused CI round on the branch or PR head (needs `gh` with access to the fork):

   ```sh
   gh workflow run ci.yml -R jerryfane/herdrup --ref <branch> \
     -f only_suite=DesktopReferenceShots -f only_device=ipad
   ```

   With `only_device=ipad`, the focused shard runs the class on both reference iPads (`desktop_reference_round` in `Tools/ci/ui-shard.sh`). Each round does the following: fresh install, dark appearance, `simctl status_bar override`, then the class. A full PR run produces the same pictures: the 13-inch round runs in the `ipad` shard and the 11-inch round in the `iphone-app` shard.

2. Download the attachments:

   ```sh
   gh run download <run-id> -R jerryfane/herdrup -n terminal-test-results-focused -D /tmp/refs
   ```

   The PNGs and their `.json` conditions are in `/tmp/refs/TestReceipts/iPadDesktopReference-first-attachments/` and `/tmp/refs/TestReceipts/iPad11DesktopReference-first-attachments/`. Each folder's `manifest.json` (written by `xcresulttool`) maps an exported file to its attachment name, `ref-<device>-<state>.png` or `.json`. The status-bar override that was used is in `TestReceipts/iPad*DesktopReference-status-bar.txt`.

3. Copy each `ref-*.png` here under its attachment name. Recompress losslessly with `zopflipng` (the `zopfli` Python package's `zopfli.png.optimize`), which keeps the decoded pixels identical and saves about 25%. Rebuild `manifest.json` from the `.json` conditions, the status-bar receipts and each PNG's `sha256sum`, and set `herdrupCommit` to the head the run built. Look at every picture before committing it.

`herdrupCommit` is the pull request head that produced the pictures. The merge commit on `main` has a different sha but the same app code.
