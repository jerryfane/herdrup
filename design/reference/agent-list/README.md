# Agent list references for Herdrup Desktop

These are pixel-exact screenshots of herdrup's Agents home on iPad, in landscape, in the regular-width `NavigationSplitView` that the Mac "Designed for iPad" app also uses. Herdrup Desktop ([jerryfane/herdrup-desktop#16](https://github.com/jerryfane/herdrup-desktop/issues/16)) must match them pixel for pixel. `../MAC-DIFFERENCES.md` lists where the Mac app differs from these iPad pictures.

`manifest.json` records, for every PNG: the device, size in points, scale, appearance, Dynamic Type size, status-bar height, override and date, mock clock, herdrup commit (and CI run, for the served states), the fixture it serves and its sha256, the avatars it shows (uploaded pictures by sha256, mascots by id), and the PNG's own sha256. `servedFixtures` lists the served states' fixtures and `avatarImage` the uploaded picture.

## What is in a picture

- **Data.** Herdrup Desktop's fake herdr roster, `cmd/fakeherdr/agents.json` at `0b5111ed47fb2325f6caf4a383758209c6d6c9f6` (sha256 `f912df09…a081e2`). It is vendored as `HerdrUITests/Fixtures/desktop-reference-agents.json` and served unchanged as the `agent.list` result by the DEBUG screenshot mock `HERDR_SCREENSHOT_MOCK=desktopref` (`App/DesktopReferenceMock.swift`). This is the data of `loading`, `empty`, `populated` and the three expansions.
- **Capabilities.** For those states `ping` advertises what a current herdr fork does (protocol 22), except `agent_groups`. The roster therefore shows no folders or stars, which matches the fixture: it defines no groups. `accounts.list` and `gram.list` answer empty, so no account lines and no Gram badge.
- **Served states.** `folders`, `avatars`, `sessions`, `federated` and both `needs-you-*` pictures serve their own fixture, `HerdrUITests/Fixtures/desktop-reference-<fixture>.json` (passed to the app as `HERDR_DESKTOPREF_SERVED`). Each is one JSON object holding every answer the state gives: `ping`, `agent.list` and `agent.groups.get` results; `agent.avatar.get` results by sha256; the output of `herdr session list --json`; and `agent.list in session`, other sessions' `agent.list` results by session name. A method without a key is refused as unknown, and `accounts.list` and `gram.list` answer empty as above. `HerdrUITests/Fixtures/PROVENANCE.md` documents the shape. Herdrup Desktop's fake herdr serves the same files, byte for byte. Each picture's fixture and its sha256 are in `manifest.json` (`fixture`, `fixtureSHA256`).
- **States** (`ref-<device>-<state>.png`):
  - `loading`: `agent.list` never answers. The sidebar spinner is frozen on its first frame. Freezing the window's layers also stops the detail column's glyph field before its first resting picture arrives, so the detail column is plain ground behind "Select an agent".
  - `empty`: `agent.list` answers with no agents ("no agents").
  - `populated`: the fixture as the roster first draws it. *Needs you* comes first (api-review blocked, docs waiting on a menu). Then *unrecognised*: studio/render, unreachable, with the offline badge. Then *working* (web, infra). Last come the closed "Idle 2" and "Archived 1" rows. *Stopped* cannot appear: it needs a pane the daemon no longer lists as live, and agent.list alone never says that. These sections have no headers (#352).
  - `idle-expanded`: Idle open (release done, notes idle).
  - `archived-expanded`: Archived open (old-spike).
  - `all-expanded`: both open. On the 11-inch the list runs past the bottom, as it would in the app.
  - `folders` (fixture `folders`): `ping` adds `agent_groups: true`. `agent.groups.get` holds Herdr (herdr-ios, herdr-app) and Enyo (enyo-review, enyo-scout), and vetrina is starred. vetrina comes first with its star, then the Herdr folder, which the test opens: its picture, "2 agents", "herdr-ios needs you" and the amber 1, then herdr-ios and herdr-app indented under it. Then the closed Enyo folder ("1 working"), jarvis, and "Idle 1" (notes). A folder sits in the section of its most urgent member.
  - `avatars` (fixture `avatars`): atlas wears an uploaded picture, nova the `cub` mascot and quill nothing, so its letter tile. The picture is `HerdrUITests/Fixtures/desktop-reference-avatar.png`, a fixed 256×256 PNG of 559 bytes, sha256 `e4d4139d5914062cd06d5b6cbd8ade1d5fddf83c20ee575d4d83b8d81de38a4a` (`avatarImage` in the manifest). It is served by `agent.avatar.get` under that sha256, and the test checks the served bytes against the file.
  - `sessions` (fixture `sessions`): `herdr session list --json` lists default, personal, scratch (not running) and work. The home is on the default session. The pills under the search field are personal · work · default (named sessions by name, the default last, `HerdrSession.decodeList`), with default selected and work carrying the amber 2: its `agent.list` has two blocked agents. A stopped session gets no pill. The roster is the default session's: web and infra working, "Idle 1".
  - `federated` (fixture `federated`): homelab/backup on a degraded peer (`agent_status` `unknown`, `last_known_status` `blocked`) sorts into *needs you* with the "!" badge and the grey "stale" pill. mac-studio/render on an unreachable peer is *unrecognised*, with the offline badge and no activity. mcb-air/scout is a reachable federated agent: the name is `<machine_label>/<name>` (`FederatedName.display`). web is local.
  - `needs-you-pill` (fixture `needs-you`): 3 agents need you (api-review and deploy blocked, docs on a menu), then 20 working. The test swipes the roster to its end, so the waiting rows are out of sight and the sticky "3 agents need you" pill shows under the "Agents" bar, with the first three waiting agents' avatars. Working rows sort by pane id as strings when no turn has completed (`AgentList.init`), so the list ends with auth (`w2:p9`).
  - `needs-you-rail` (fixture `needs-you`): the sidebar minimised (the bar's Minimise sidebar button) to the rail, which shows the amber 3 (need you) and the blue 20 (working) under the section icons. The Agents tab itself has no count on iPad: `tabBadgeCount(for:gram:)` returns 0 for `.agents` (`App/HerdrApp.swift`). The count is the rail's and the pill's.
- **Devices.** `ipad-pro-13` is the iPad Pro 13-inch at 1376×1032 pt. `ipad-11` is an 1180×820 pt iPad (iPad Air 11-inch, or the base iPad (A16) when the runner lacks it). Both are @2x, landscape and full screen.
- **Held still.** Dark appearance and the default Dynamic Type size (Large). UIKit and SwiftUI animations are off, and the working ring is drawn at rest. The empty detail column's glyph field is drawn once from a fixed seed (SplitMix64 `0x4845524452555031`, `FieldDice` in `App/SelectAgentField.swift`), with no lens, twinkle or typing. The roster's clock is pinned to `2026-10-28T09:41:00Z` (`HERDR_MOCK_NOW`). That clock is behind the only relative time the list draws: a row's time in its state (`compactTimeInState` in `card`). The fakeherdr fixture has no `status_since_unix_ms`, so the first six states draw no age. Every agent in the served fixtures has an absolute `status_since_unix_ms` a fixed number of minutes before that clock (4m, 37m, 2h, 9h, 3d, 12m, 55m, 5h, 26m, 2d in list order, repeating), so their rows draw that age before the chevron. The status bar is overridden to 9:41, full charged battery, three Wi-Fi bars and no cellular, and is 32 pt tall. simctl on this image accepts only a plain time, so the date beside it is the runner's real date: "Wed Oct 28" in the six states first committed (`loading` to `all-expanded`), "Thu Oct 29" in the served states. A later run of the first six on 2026-10-29 (run 40896841718) differed from the committed pictures only in those date pixels (the box from x 158 to 330, y 21 to 43 in pixels), so they were kept. A capture is kept only after three screenshots 0.5 s apart are byte-identical.

## Regenerating

1. Run the focused CI round on the branch or PR head (needs `gh` with access to the fork):

   ```sh
   gh workflow run ci.yml -R themartianapp/herdrup --ref <branch> \
     -f only_suite=DesktopReferenceShots -f only_device=ipad
   ```

   With `only_device=ipad`, the focused shard runs the class on both reference iPads (`desktop_reference_round` in `Tools/ci/ui-shard.sh`). Each round does the following: fresh install, dark appearance, `simctl status_bar override`, then the class. A full PR run produces the same pictures: the 13-inch round runs in the `ipad` shard and the 11-inch round in the `iphone-app` shard.

2. Download the attachments:

   ```sh
   gh run download <run-id> -R themartianapp/herdrup -n terminal-test-results-focused -D /tmp/refs
   ```

   The PNGs and their `.json` conditions are in `/tmp/refs/TestReceipts/iPadDesktopReference-first-attachments/` and `/tmp/refs/TestReceipts/iPad11DesktopReference-first-attachments/`. Each folder's `manifest.json` (written by `xcresulttool`) maps an exported file to its attachment name, `ref-<device>-<state>.png` or `.json`. The status-bar override that was used is in `TestReceipts/iPad*DesktopReference-status-bar.txt`.

3. Copy each `ref-*.png` here under its attachment name. Recompress losslessly with `zopflipng` (the `zopfli` Python package's `zopfli.png.optimize`), which keeps the decoded pixels identical and saves about 25%. Rebuild `manifest.json` from the `.json` conditions, the status-bar receipts and each PNG's `sha256sum`, and set `herdrupCommit` to the head the run built. Look at every picture before committing it.

`herdrupCommit` is the pull request head that produced the pictures (per file; the served states have their own, with their `ciRun`). The merge commit on `main` has a different sha but the same app code.
