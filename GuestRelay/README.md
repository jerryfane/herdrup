# herdrup-guest

`herdrup-guest` is the Cloudflare Worker behind HerdrUp guest access (herdrup#309,
#310). An owner shares one agent with someone outside their fleet. The guest's HerdrUp
reaches the host daemon that runs the agent through this relay, so the host needs no
SSH access and no open ports.

```
guest iPhone ──WSS──► herdrup-guest (one Durable Object per host) ◄──WSS── host daemon
        └──────────── Noise_IK end to end: the relay only pipes ciphertext ────────────┘
```

The host keeps one WebSocket open to the relay. Each guest connection becomes a numbered
session on that socket. The guest and the host run a Noise_IK handshake through the
relay, which authenticates the guest's device key and encrypts everything after that.
The relay never holds a key that can read the traffic.

## Privacy

- **Logs:** each log line is a JSON object with only `endpoint`, `outcome` and, for
  closes, `code`. The relay never logs payloads, the close reasons that peers send,
  secrets, host ids, IP addresses or request paths. The `/i` landing page and its assets
  are served before the Worker runs. `/i/<payload>` reaches the Worker, which hands it the
  same page from `ASSETS` without logging anything.
- **Platform logs:** `wrangler.toml` turns off Workers Logs (including invocation logs,
  which record every request URL), traces and Logpush, so Cloudflare keeps no record of
  invite paths. `wrangler tail` still shows request URLs to whoever runs it, so don't tail
  a production relay while invites are in use.
- **Storage:** each host's Durable Object stores two things in SQLite: the SHA-256 of the
  host's relay secret, and the next session id.
- **Invite links:** the invite lives in the path of `/i/<payload>`, so it reaches the
  Worker once, on the way to the landing page. Nothing stores or logs it, and the page is
  `Cache-Control: no-store` and `Referrer-Policy: no-referrer`. The "Open in HerdrUp"
  button carries it in the fragment of `herdrup://guest-invite#<payload>`, which never
  leaves the device.
  - The earlier `/i#<payload>` form kept the invite away from the server, but iMessage
    splits a link at `#` into two messages, so the recipient got a bare `/i` link and a
    stray `#eyJ…` text. The page still reads the fragment, so old links keep working.

## Endpoints

| Endpoint | Behaviour |
| --- | --- |
| `GET /v1/health` | 200 `{"ok":true,"version":"…"}` |
| `GET /i/<payload>` | The invite landing page. `<payload>` is the b64url invite (`A-Z a-z 0-9 - _`, 1 to 4096 characters); anything else is 404 `not_found`. The page's script reads the payload from the path, shows who shared which agent, and links "Open in HerdrUp" to `herdrup://guest-invite#<payload>`. It also links to the App Store. |
| `GET /i` | The same page for older `/i#<payload>` links: its script falls back to `location.hash`. |
| `GET /v1/host/<host_id>` | The host's WebSocket. Needs `Authorization: Bearer <relay_secret>`. |
| `GET /v1/guest/<host_id>` | A guest WebSocket. No auth here: Noise authenticates the guest. |

A `host_id` is b64url (no padding) of 16 bytes, so 22 characters. A `relay_secret` is
b64url of 32 bytes, so 43 characters. The Durable Object is `idFromName(host_id)`.

Every error before the WebSocket upgrade returns JSON `{"error":"<code>"}` and also
sends the header `X-Herdr-Guest-Error: <code>`. The header is there because
URLSessionWebSocketTask can't read the body of a failed upgrade.

| Status | Code | When |
| --- | --- | --- |
| 401 | `unauthorized` | Host only. The bearer is missing or malformed (refused in the Worker, before any Durable Object), or its hash doesn't match the stored one. |
| 503 | `host_offline` | Guest only. No host socket is connected. |
| 503 | `host_busy` | Guest only. The host already has 32 open sessions. |
| 429 | `rate_limited` | Either role, keyed by `CF-Connecting-IP`: more than 30 guest connects, or more than 10 host connects, in 60 s. Checked before the Durable Object is reached. |
| 426 | `upgrade_required` | Either role. The request isn't a WebSocket upgrade. |
| 404 | `not_found` | Any other method or path, or a malformed `host_id`. |

### Host authentication

The relay uses trust on first use:
- The first host connect for a `host_id` stores SHA-256 of its secret.
- Every later connect must match that hash. The relay compares with
  `crypto.subtle.timingSafeEqual`. A mismatch gets 401.

There is only one host socket at a time. A newer authenticated connect replaces the old
socket, which closes with code **4000**. Its guests close with 1001 `host_offline`.

### Framing

A guest socket carries raw bytes: each binary message is one DATA payload.

Messages on the host socket are binary frames: `type u8 | session u32 BE | payload`.

| Type | Direction | Payload |
| --- | --- | --- |
| `0x01` OPEN | relay → host | Empty. A guest connected. |
| `0x02` DATA | both ways | The bytes from or for that guest. |
| `0x03` CLOSE | both ways | Host → relay: an optional UTF-8 reason of at most 123 bytes, which becomes the guest's close reason. Relay → host: always empty. |

Session ids start at 1 and increase. They are stored per `host_id`, so they keep
increasing across host reconnects and Durable Object restarts. After 2^32−1 they wrap
to 1, and allocation skips any id that a socket still holds.

### Close propagation and limits

- **Guest closes:** the host gets CLOSE for that session.
- **Host sends CLOSE:** the guest closes with 1000 and the host's reason. A reason that
  is over 123 bytes or isn't valid UTF-8 is sent empty.
- **Host socket drops or is replaced:** every one of its guests closes with 1001
  `host_offline`.
- **Oversize message:** a message over **70000 bytes** closes the socket that sent it
  with **1009**. For a host frame, the 5-byte header counts toward the limit.
- **Guest protocol errors:**
  - text other than `ping` closes the guest with 1003;
  - when the relay closes a guest itself (1009 or 1003), the host gets CLOSE for that
    session.
- **Host protocol errors:**
  - text other than `ping` closes the host with 1003;
  - a frame under 5 bytes, an OPEN from the host, or an unknown type closes it with 1002;
  - DATA or CLOSE for a session that isn't open is dropped.
- **Keepalive:** a text `ping` from either side gets a text `pong` from the hibernation
  auto-response, without waking the Durable Object. The host pings every 25 s.

The Durable Object uses the WebSocket Hibernation API. Routing lives in socket tags and
attachments, and the secret hash and session counter live in SQLite, so an idle host
costs nothing while its object hibernates.

## Bindings

| Binding | Kind | Purpose |
| --- | --- | --- |
| `HOSTS` | Durable Object `HostRelay` (SQLite, migration `v1`) | One object per `host_id` |
| `GUEST_CONNECT_LIMIT` | Rate limit, 30 per 60 s | Guest connects, keyed by `CF-Connecting-IP` |
| `HOST_CONNECT_LIMIT` | Rate limit, 10 per 60 s | Host connects, keyed by `CF-Connecting-IP` |
| `ASSETS` | Static assets from `public/` | The `/i` page. The Worker serves it for `/i/<payload>`, which matches no file. |

The Worker needs no secrets.

## Develop and deploy

Needs Node 22 or later (`engines` in `package.json`), because the pinned wrangler
requires it.

```sh
cd GuestRelay
npm install
npm test                 # vitest in workerd, against the real Durable Object
npm run typecheck
npx wrangler deploy --dry-run --outdir /tmp/guestrelay-dry   # bundle check only
wrangler deploy
```

`wrangler.toml` routes the custom domain `guest.herdrup.themartian.app` with
`custom_domain = true`, so the first `wrangler deploy` attaches it. The
`themartian.app` zone must be on the deploying account. To attach the domain by hand,
remove the `routes` line and use the dashboard: Workers → herdrup-guest → Settings →
Domains & Routes.

## Rollback

- **Bad code in a later version:** run `wrangler deployments list` and then
  `wrangler rollback <version-id>`. You can also pick a version in the dashboard under
  Deployments. Rollback can't cross a Durable Object migration. For a version from
  before a migration, deploy a fixed version instead.
- **Take guest access offline:** detach `guest.herdrup.themartian.app` in Domains &
  Routes. The Worker and its stored host hashes stay intact.
  - Host daemons keep retrying with backoff: 2 s, doubling to 60 s.
  - Guests see the relay as unreachable.
  - Reattach the domain to restore service. Hosts reconnect by themselves.
- **Remove the relay entirely:** run `wrangler delete`. This also deletes every host's
  stored secret hash. A redeploy then trusts the first connect again, as on day one.
  Hosts reconnect with their existing `host.json`. Until a host reconnects, anyone who
  knows its `host_id` from an invite could claim it first. Noise still stops them from
  posing as the host, but the real host gets 401 until it makes a new `host.json`, and
  that invalidates its invites.
- **Revoke one guest:** this happens on the host, not the relay. Run
  `herdr guest revoke <id>` there.
