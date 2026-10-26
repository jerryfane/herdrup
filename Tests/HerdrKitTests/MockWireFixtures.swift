import Foundation

#if DEBUG
/// THE MOCK WIRE FIXTURES: canned herdr JSON answers, one copy compiled into two targets.
///
/// HerdrKitTests compiles it with the rest of the test target, and `MockWireFixtureTests`
/// decodes every fixture through the real `HerdrClient` path (the app target can't be
/// compiled on Linux, so that is where the JSON is machine-checked). The Herdr app compiles
/// it too (project.yml lists this file in the Herdr target's sources), and its DEBUG
/// `MockTransport` answers with these same bytes, so the mock render and the tests cannot
/// drift. Foundation only: no UIKit, no HerdrKit types, so it builds in both.
///
/// DEBUG only: the app's MockTransport is, and a Release build should carry none of this.
enum MockWireFixtures {
    /// An `agent.list` answer. Realistic herdr statuses only (idle|working|blocked|done|
    /// unknown). "needs you" is `blocked`; the STOPPED row is NOT a status string — it comes
    /// from liveness (w2:p1 is absent from `demoLivePaneIDs`), exactly as the real model
    /// derives it. done folds into idle.
    /// The mcb-air row is a DEGRADED FEDERATED agent: the daemon blanked `agent_status` to
    /// "unknown" after a missed poll and moved the real state into `last_known_status`, so
    /// it escalates into NEEDS YOU on a last-known value and must render the "stale" marker.
    /// It is what the UI receipt asserts.
    static let agentList = #"""
    {"id":"mock","result":{"type":"agent_list","agents":[
      {"pane_id":"w1:p1","name":"jarvis","agent":"claude","agent_status":"blocked","cwd":"/root/herdr-ios","terminal_title_stripped":"asking to run tests"},
      {"pane_id":"w1:p2","name":"vetrina","agent":"codex","agent_status":"blocked","cwd":"/root/vetrina","terminal_title_stripped":"overwrite config.ts?"},
      {"pane_id":"w2:p1","name":"trend-scout","agent":"codex","agent_status":"idle","cwd":"/root/trend-scout","terminal_title_stripped":"exited, code 1"},
      {"pane_id":"w2:p2","name":"herdr-app","agent":"claude","agent_status":"working","cwd":"/root/herdr","terminal_title_stripped":"editing src/acp.rs","account":"claudecrazy","account_config_dir":"/root/.claude-9"},
      {"pane_id":"w3:p1","terminal_id":"t-clientloop","name":"clientloop","avatar":{"style":"mascot","mascot":"tri","sha256":null,"updated_unix_ms":1723041000000},"agent":"claude","agent_status":"idle","cwd":"/root/clientloop","terminal_title_stripped":"amigo-poc scaffold","account":"retired-account","account_unresolved":true},
      {"pane_id":"w3:p2","name":"aste-screener","agent":"codex","agent_status":"idle","cwd":"/root/aste-screener","terminal_title_stripped":"apify-harvest"},
      {"pane_id":"w4:p1","terminal_id":"t-discovery","name":"discovery","avatar":{"style":"image","mascot":null,"sha256":"20d7932ab0342ec9aab4e2e3c26e95051c987786fb98c2ac2e4ef2ddc5ca8a99","updated_unix_ms":1723041000000},"agent":"gemini","agent_status":"idle","cwd":"/root/discovery-calls","terminal_title_stripped":"redaction-pass v3"},
      {"pane_id":"w4:p2","name":"bank-qa","agent":"claude","agent_status":"done","cwd":"/root/bank-qa","terminal_title_stripped":"deal-assistant rag"},
      {"pane_id":"mcb-air/w1:p9","name":"mcb-air/mcb-air","agent":"omp","agent_status":"unknown","last_known_status":"blocked","machine_id":"mcb-air","reachability":"degraded","cwd":"/Users/jerry/omp-workspace","terminal_title_stripped":"clone repo and help deimos"},
      {"pane_id":"w5:p1","name":"huurjacht","agent":"claude","agent_status":"idle","cwd":"/root/huurjacht","terminal_title_stripped":"pararius scrape","archived":{"at":"2026-08-26T18:00:00Z","by":"jerry","reason":"parked for the weekend"}}
    ]}}
    """#

    /// The photo `discovery` wears in `agentList` (herdrup#538): a 32 px PNG of orange and
    /// violet bands, answered by the mock `agent.avatar.get`. Its sha256 is the descriptor's.
    static let avatarImageSHA256 = "20d7932ab0342ec9aab4e2e3c26e95051c987786fb98c2ac2e4ef2ddc5ca8a99"
    static let avatarImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAM0lEQVR42mN4McmGpohh1IJRC4aABd2V32iKRi0YtWAoWDBaVIxaMGrBaH0wasGoBUAEAADlYGrPeOfmAAAAAElFTkSuQmCC"
    static let avatarImage = #"{"id":"mock","result":{"type":"agent_avatar_image","mime":"image/png","data_base64":"\#(avatarImageBase64)"}}"#

    /// The panes herdr still lists, for the mock render. Excludes w2:p1 so that row lands
    /// in STOPPED via liveness (not a status string). Includes the federated `mcb-air/w1:p9`,
    /// because a pane absent from the census is `.stopped` and a stopped row is never
    /// escalated, which would silently defeat the degraded-peer receipt.
    static let demoLivePaneIDs: Set<String> = [
        "w1:p1", "w1:p2", "w2:p2", "w3:p1", "w3:p2", "w4:p1", "w4:p2", "mcb-air/w1:p9",
    ]

    /// An `agent.read` answer: the mock pane's recent text.
    static let agentRead = #"""
    {"id":"mock","result":{"read":{"pane_id":"w1:p1","text":"$ herdr agent attach jarvis\n\n> Ran 146 tests, 0 failures\n> Edited SessionRecoveryTests.swift  +18 -4\n\nRun `swift test` with -Xswiftc -warnings-as-errors?\n  1. yes\n  2. no, skip it\n>\n\n[demo data - mock render mode, no live connection]","truncated":false,"source":"recent_unwrapped","format":"text"}}}
    """#

    /// An `accounts.list` owner view, for the Settings mock render: two claude accounts (one
    /// active with usage, one exhausted), a codex account with tier-only usage (no percent),
    /// and a kimi account with no usage at all. Exercises every optionality of AccountUsage.
    static let accountsList = #"""
    {"id":"mock","result":{"type":"accounts_list","accounts":[
      {"id":"acc-claude-1","kind":"claude","label":"Claude Max (work)","active":true,"email":"work@example.com","usage":{"source":"live","windows":[{"label":"5h","used_percent":42,"resets_at":"2000000000","status":"ok"},{"label":"weekly","used_percent":68,"resets_at":"2030-01-15T18:00:00Z","status":"ok"}],"primary_used_percent":42,"secondary_used_percent":68,"resets_at":"2026-08-20T18:00:00Z","plan":"Max"}},
      {"id":"acc-claude-2","kind":"claude","label":"Claude Pro (personal)","active":false,"email":"personal@example.com","usage":{"primary_used_percent":100,"secondary_used_percent":100,"plan":"Pro"}},
      {"id":"acc-codex-1","kind":"codex","label":"Codex (team)","active":true,"email":"team@example.com","usage":{"tier":"Plus"}},
      {"id":"acc-kimi-1","kind":"kimi","label":"Kimi","active":true}
    ]}}
    """#

    /// A `gram.list` owner view for the Gram-page mock render: the sample conversation of the
    /// approved design (you, vetrina and ci-watch on this machine, clientloop and trend-scout
    /// relayed from hetzner-1), newest first, plus a second, local clientloop so the composer's
    /// @ list has two agents with one name. It has direct owner posts and a grabbed
    /// shared-queue post. Yesterday's thread is read; today's three agent messages are unread:
    /// a long report that folds, an image, and a code fence with a zip. Yesterday trend-scout
    /// also sent two files the store has since expired (herdr#298): a chart with no caption
    /// (g12) and an export under a line of text (g11).
    static let gramList = #"""
    {"id":"mock","result":{"type":"gram_list","messages":[
      {"id":"g1","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Great, ship it.","created_unix_ms":1723041360000,"read_by_owner":true},
      {"id":"g2","direction":"agent_to_owner","from":"4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/clientloop","machine_label":"hetzner-1","text":"Scaffold is up. Run it with:\n```\ncd ~/src/amigo-poc && pnpm dev\n```","created_unix_ms":1723041240000,"read_by_owner":false,"file":{"name":"amigo-poc-scaffold.zip","size":1363149,"mime":"application/zip","sha256":"3d5e7f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c"}},
      {"id":"g3","direction":"agent_to_owner","from":"vetrina","text":"","created_unix_ms":1723041160000,"read_by_owner":false,"file":{"name":"vetrina-live.png","size":421888,"mime":"image/png","sha256":"9f2c0a1b7d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e"}},
      {"id":"g4","direction":"agent_to_owner","from":"vetrina","text":"Deployed. vetrina.dev is live.\n• Build 412 passed in 3m 08s\n• 2 migrations ran clean\n• Lighthouse 98 on mobile\n• CDN cache purged, EU and US\n• Sitemap resubmitted\n• Stripe webhooks verified\n• Sentry: no new issues\n• Uptime check green for 10 min\nRollback is one command away:\nherdr rollback vetrina 411","created_unix_ms":1723041130000,"read_by_owner":false},
      {"id":"g5","direction":"owner_to_agent","from":"owner","text":"Who can triage the failing CI?","grabbed_by":"ci-watch","grabbed_unix_ms":1722970020000,"created_unix_ms":1722969900000,"read_by_owner":true},
      {"id":"g6","direction":"agent_to_owner","from":"4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/trend-scout","machine_label":"hetzner-1","text":"Digest ready: 7 trends, 2 need your call.","created_unix_ms":1722969600000,"read_by_owner":true},
      {"id":"g12","direction":"agent_to_owner","from":"4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/trend-scout","machine_label":"hetzner-1","text":"","created_unix_ms":1722969540000,"read_by_owner":true,"expired_file":{"name":"trend-chart.png","size":873472,"mime":"image/png","sha256":"18ce5c6f97913baa79fe27d910e2f8be0f57ca89104e1ebda73840653e30be7b"}},
      {"id":"g11","direction":"agent_to_owner","from":"4b1e9c0d7a2f48e6b3c5d8f01a6e2b97/trend-scout","machine_label":"hetzner-1","text":"Raw export of the run, for the record.","created_unix_ms":1722969480000,"read_by_owner":true,"expired_file":{"name":"trend-export.csv","size":2516582,"mime":"text/csv","sha256":"65b440e08c55e62678952c82b42e9e7898f0665f43fb9fe2733f74b7d580d6a9"}},
      {"id":"g10","direction":"agent_to_owner","from":"clientloop","text":"Lint is clean on my branch.","created_unix_ms":1722969000000,"read_by_owner":true},
      {"id":"g7","direction":"agent_to_owner","from":"vetrina","text":"On it. Waiting on CI.","created_unix_ms":1722968460000,"read_by_owner":true},
      {"id":"g8","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Good. Deploy when CI is green.","created_unix_ms":1722968400000,"read_by_owner":true},
      {"id":"g9","direction":"agent_to_owner","from":"vetrina","text":"Picked up the deploy ticket.\nRebasing onto main first.","created_unix_ms":1722967500000,"read_by_owner":true}
    ]}}
    """#

    /// The paged mock's second page, newest first, all older than g9.
    static let gramOlderRows = #"""
      {"id":"go1","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Thanks. Take the deploy ticket next.","created_unix_ms":1722884400000,"read_by_owner":true},
      {"id":"go2","direction":"agent_to_owner","from":"vetrina","text":"Smoke tests pass on staging.\nAll 38 checks green.","created_unix_ms":1722884100000,"read_by_owner":true},
      {"id":"go3","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Run the smoke tests too.","created_unix_ms":1722883800000,"read_by_owner":true},
      {"id":"go4","direction":"agent_to_owner","from":"vetrina","text":"Added the rollback step.\nStaging is green.","created_unix_ms":1722883500000,"read_by_owner":true},
      {"id":"go5","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Add a rollback step before the migration.","created_unix_ms":1722883200000,"read_by_owner":true},
      {"id":"go6","direction":"agent_to_owner","from":"vetrina","text":"Checklist is in docs/release.md.\nEight steps, two need a sign-off.","created_unix_ms":1722882900000,"read_by_owner":true},
      {"id":"go7","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Draft the release checklist first.","created_unix_ms":1722882600000,"read_by_owner":true},
      {"id":"go8","direction":"agent_to_owner","from":"vetrina","text":"Bundle size is down 14 percent.\nThe image pipeline was the culprit.","created_unix_ms":1722882300000,"read_by_owner":true},
      {"id":"go9","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Nice. Keep an eye on the cold start.","created_unix_ms":1722882000000,"read_by_owner":true},
      {"id":"go10","direction":"agent_to_owner","from":"vetrina","text":"Cold start is 1.2 s on a mid-range phone.\nWithin budget.","created_unix_ms":1722881700000,"read_by_owner":true},
      {"id":"go11","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"What changed in the cache layer?","created_unix_ms":1722881400000,"read_by_owner":true},
      {"id":"go12","direction":"agent_to_owner","from":"vetrina","text":"Swapped the LRU for a size-bounded one.\nEvictions dropped by half.","created_unix_ms":1722881100000,"read_by_owner":true},
      {"id":"go13","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Good. Write that up for the changelog.","created_unix_ms":1722880800000,"read_by_owner":true},
      {"id":"go14","direction":"agent_to_owner","from":"vetrina","text":"Changelog entry drafted.\nIt is in the release branch.","created_unix_ms":1722880500000,"read_by_owner":true},
      {"id":"go15","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Did the flaky login test settle?","created_unix_ms":1722880200000,"read_by_owner":true},
      {"id":"go16","direction":"agent_to_owner","from":"vetrina","text":"It was a timezone bug in the fixture.\nFixed and green 20 runs in a row.","created_unix_ms":1722879900000,"read_by_owner":true},
      {"id":"go17","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Great catch. Merge it.","created_unix_ms":1722879600000,"read_by_owner":true},
      {"id":"go18","direction":"agent_to_owner","from":"vetrina","text":"Merged. CI is rebuilding main.","created_unix_ms":1722879300000,"read_by_owner":true},
      {"id":"go19","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Ping me when main is green.","created_unix_ms":1722879000000,"read_by_owner":true},
      {"id":"go20","direction":"agent_to_owner","from":"vetrina","text":"Main is green.\nTagging a release candidate.","created_unix_ms":1722878700000,"read_by_owner":true},
      {"id":"go21","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Hold the tag until the docs land.","created_unix_ms":1722878400000,"read_by_owner":true},
      {"id":"go22","direction":"agent_to_owner","from":"vetrina","text":"Docs PR is open.\nTwo screenshots still to refresh.","created_unix_ms":1722878100000,"read_by_owner":true},
      {"id":"go23","direction":"owner_to_agent","from":"owner","to":"vetrina","text":"Start with the release planning.","created_unix_ms":1722877800000,"read_by_owner":true},
      {"id":"go24","direction":"agent_to_owner","from":"vetrina","text":"Older page: release planning starts here.","created_unix_ms":1722877500000,"read_by_owner":true}
    """#

    /// The paged mock's last page: one row, older than go24.
    static let gramOldestRows = #"""
      {"id":"gx1","direction":"agent_to_owner","from":"vetrina","text":"Oldest page: kickoff notes are in the repo.","created_unix_ms":1722796200000,"read_by_owner":true}
    """#

    /// A `gram.list` answer from comma-joined row blocks.
    static func gramListAnswer(rows: [String], hasMore: Bool) -> String {
        #"{"id":"mock","result":{"type":"gram_list","messages":["#
            + rows.joined(separator: ",") + #"],"has_more":"# + (hasMore ? "true" : "false") + "}}"
    }

    /// `gramList`'s message rows, without the envelope.
    static var gramListRows: String {
        let open = gramList.range(of: #""messages":["#)!.upperBound
        let close = gramList.range(of: "]}}", options: .backwards)!.lowerBound
        return String(gramList[open..<close])
    }

    /// A canned `gram.post` echo (`type: gram_sent`), so the mock composer's send path resolves.
    static let gramPosted =
        #"{"id":"mock","result":{"type":"gram_sent","message":{"id":"gp1","direction":"owner_to_agent","from":"owner","text":"(sent)","created_unix_ms":1723041420000,"read_by_owner":true}}}"#

    /// A canned `gram.get_file` reply (`type: gram_file_content`); the bytes decode
    /// to "hello world".
    static let gramFileContent =
        #"{"id":"mock","result":{"type":"gram_file_content","name":"vetrina-live.png","mime":"image/png","size":11,"data_base64":"aGVsbG8gd29ybGQ="}}"#

    /// The HTML mock's row (`HERDR_MOCK_GRAM_HTML`): vetrina's run report (gh1), an HTML
    /// file, read.
    static let gramHtmlRow =
        #"{"id":"gh1","direction":"agent_to_owner","from":"vetrina","text":"Run report attached.","created_unix_ms":1723041420000,"read_by_owner":true,"file":{"name":"run-report.html","size":90,"mime":"text/html","sha256":"d78f7bf51215300da41164a777bd546b14995a93350f629717cfe83458e3f8b3"}}"#

    /// The `gram.get_file` reply for gh1: the report's 90 bytes of HTML.
    static let gramHtmlContent =
        #"{"id":"mock","result":{"type":"gram_file_content","name":"run-report.html","mime":"text/html","size":90,"data_base64":"PCFkb2N0eXBlIGh0bWw+PG1ldGEgY2hhcnNldD0idXRmLTgiPjx0aXRsZT5SdW4gcmVwb3J0PC90aXRsZT48cD5BbGwgMTQ2IHRlc3RzIHBhc3NlZC48L3A+"}}"#

    /// A canned `type: ok` reply, for `gram.upload_chunk` and `gram.delete`.
    static let gramOk = #"{"id":"mock","result":{"type":"ok"}}"#

    // MARK: pane.stream / pane.set_pty_size, for the live terminal

    /// The `pane.stream` open ack: the geometry-carrying `stream_started` line.
    static let paneStreamAck =
        #"{"id":"mock","result":{"type":"stream_started","pane_id":"w1:p1","epoch":7,"cols":80,"rows":24,"base_seq":0,"resync":true}}"#

    /// The reset seed frame. `data_b64` is a full-screen ANSI snapshot (clear +
    /// home + a demo screen); it decodes to text containing "mock render".
    static let paneStreamReset =
        #"{"stream":"pane.bytes","frame":"reset","seq":0,"epoch":7,"cols":80,"rows":24,"data_b64":"G1syShtbSBtbMTszODs1OzM5bWhlcmRyG1swbSBsaXZlIHRlcm1pbmFsIOKAlCBtb2NrIHJlbmRlcg0KDQokIGhlcmRyIGFnZW50IGF0dGFjaCBqYXJ2aXMNCj4gUmFuIDE0NiB0ZXN0cywgMCBmYWlsdXJlcw0KDQpbZGVtbyBkYXRhIOKAlCBubyBsaXZlIGNvbm5lY3Rpb25dDQo="}"#

    /// The `pane.set_pty_size` reply. The current server's `PanePtySize` variant is
    /// exactly {pane_id, cols, rows, locked} — no epoch.
    static let panePtySize =
        #"{"id":"mock","result":{"type":"pane_pty_size","pane_id":"w1:p1","cols":80,"rows":24,"locked":false}}"#
}
#endif
