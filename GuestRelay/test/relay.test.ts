import { SELF, env, evictDurableObject, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Everything here runs against the real Worker and Durable Object in workerd. Each test
// uses its own host_id and client IPs, so storage and rate-limit state never collide.

const ORIGIN = "https://guest.herdrup.themartian.app";
const OPEN = 0x01;
const DATA = 0x02;
const CLOSE = 0x03;
const MAX_MESSAGE = 70_000;

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const newHostId = () => b64url(crypto.getRandomValues(new Uint8Array(16)));
const newSecret = () => b64url(crypto.getRandomValues(new Uint8Array(32)));

let ipCounter = 0;
const freshIp = () => `2001:db8::${(++ipCounter).toString(16)}`;

const utf8 = (text: string) => new TextEncoder().encode(text);
const text = (bytes: Uint8Array) => new TextDecoder().decode(bytes);

function frame(type: number, session: number, payload: Uint8Array = new Uint8Array(0)): ArrayBuffer {
  const bytes = new Uint8Array(5 + payload.byteLength);
  bytes[0] = type;
  new DataView(bytes.buffer).setUint32(1, session);
  bytes.set(payload, 5);
  return bytes.buffer;
}

interface Frame {
  type: number;
  session: number;
  payload: Uint8Array;
}

function parse(message: ArrayBuffer | string): Frame {
  if (typeof message === "string") throw new Error(`expected a binary frame, got text ${message}`);
  const view = new DataView(message);
  return { type: view.getUint8(0), session: view.getUint32(1), payload: new Uint8Array(message, 5) };
}

interface Closed {
  code: number;
  reason: string;
}

/** One end of a WebSocket, with its messages queued in order. A missing message or close fails on the test timeout. */
class Peer {
  private readonly queue: (ArrayBuffer | string)[] = [];
  private readonly waiters: ((message: ArrayBuffer | string) => void)[] = [];
  private readonly closeEvent = Promise.withResolvers<Closed>();
  /** The close code and reason this end received. */
  readonly closed = this.closeEvent.promise;

  constructor(readonly ws: WebSocket) {
    ws.binaryType = "arraybuffer";
    ws.accept();
    ws.addEventListener("message", (event) => {
      const waiter = this.waiters.shift();
      if (waiter) waiter(event.data as ArrayBuffer | string);
      else this.queue.push(event.data as ArrayBuffer | string);
    });
    ws.addEventListener("close", (event) => {
      this.closeEvent.resolve({ code: event.code, reason: event.reason });
    });
  }

  next(): Promise<ArrayBuffer | string> {
    const queued = this.queue.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    const { promise, resolve } = Promise.withResolvers<ArrayBuffer | string>();
    this.waiters.push(resolve);
    return promise;
  }

  async nextFrame(): Promise<Frame> {
    return parse(await this.next());
  }

  send(message: ArrayBuffer | Uint8Array | string): void {
    this.ws.send(message);
  }
}

interface GuestSession {
  guest: Peer;
  session: number;
}

function hostRequest(hostId: string, authorization?: string, upgrade = true): Promise<Response> {
  const headers: Record<string, string> = {};
  if (upgrade) headers.Upgrade = "websocket";
  if (authorization !== undefined) headers.Authorization = authorization;
  return SELF.fetch(`${ORIGIN}/v1/host/${hostId}`, { headers });
}

function guestRequest(hostId: string, ip = freshIp(), upgrade = true): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": ip };
  if (upgrade) headers.Upgrade = "websocket";
  return SELF.fetch(`${ORIGIN}/v1/guest/${hostId}`, { headers });
}

async function connectHost(hostId: string, secret: string): Promise<Peer> {
  const response = await hostRequest(hostId, `Bearer ${secret}`);
  expect(response.status).toBe(101);
  return new Peer(response.webSocket!);
}

/** Connects a guest and returns it with the session id the host was told in OPEN. */
async function connectGuest(host: Peer, hostId: string, ip?: string): Promise<GuestSession> {
  const response = await guestRequest(hostId, ip);
  expect(response.status).toBe(101);
  const guest = new Peer(response.webSocket!);
  const open = await host.nextFrame();
  expect(open.type).toBe(OPEN);
  expect(open.payload.byteLength).toBe(0);
  return { guest, session: open.session };
}

/** An error before the upgrade: status, JSON body and the X-Herdr-Guest-Error header agree. */
async function expectError(response: Response, status: number, code: string): Promise<void> {
  expect(response.status).toBe(status);
  expect(response.webSocket).toBeNull();
  expect(response.headers.get("X-Herdr-Guest-Error")).toBe(code);
  expect(await response.json()).toEqual({ error: code });
}

const stub = (hostId: string) => env.HOSTS.get(env.HOSTS.idFromName(hostId));

describe("routing", () => {
  it("answers health", async () => {
    const response = await SELF.fetch(`${ORIGIN}/v1/health`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, version: expect.any(String) });
  });

  // Asset requests never reach the Worker (so /i is never logged); SELF skips the asset
  // router in tests, so the page is fetched through the ASSETS binding instead.
  it("serves the invite landing page and every asset it references, locked down by CSP", async () => {
    const response = await env.ASSETS.fetch(`${ORIGIN}/i`);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toMatch(/^text\/html/);
    expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    const html = await response.text();
    expect(html).toContain('href="https://apps.apple.com/app/id6798087089"');

    const css = await (await env.ASSETS.fetch(`${ORIGIN}/static/i.css`)).text();
    const refs = [...html.matchAll(/(?:src|href)="(\/[^"]+)"/g), ...css.matchAll(/url\((\/[^)]+)\)/g)].map((m) => m[1]);
    expect(refs).toEqual(expect.arrayContaining(["/static/i.js", "/static/i.css", "/fonts/Geist-Regular.woff2"]));
    for (const ref of refs) expect([ref, (await env.ASSETS.fetch(`${ORIGIN}${ref}`)).status]).toEqual([ref, 200]);
  });

  it("rejects unknown paths, malformed host ids and other methods with not_found", async () => {
    const hostId = newHostId();
    await expectError(await SELF.fetch(`${ORIGIN}/v1/nope`), 404, "not_found");
    await expectError(await hostRequest(hostId.slice(1), `Bearer ${newSecret()}`), 404, "not_found");
    await expectError(await guestRequest(`${hostId}A`), 404, "not_found");
    await expectError(await guestRequest(`${hostId.slice(2)}+/`), 404, "not_found");
    // workerd's fetch() sends every Upgrade: websocket request as GET, so the method check is probed without it.
    await expectError(await SELF.fetch(`${ORIGIN}/v1/guest/${hostId}`, { method: "POST" }), 404, "not_found");
  });

  it("requires a WebSocket upgrade on both socket endpoints", async () => {
    const hostId = newHostId();
    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}`, false), 426, "upgrade_required");
    await expectError(await guestRequest(hostId, freshIp(), false), 426, "upgrade_required");
  });
});

describe("host authentication", () => {
  it("trusts the first secret, refuses any other, and stores only its hash", async () => {
    const hostId = newHostId();
    const secret = newSecret();
    const host = await connectHost(hostId, secret);

    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}`), 401, "unauthorized");
    // The refused connect left the trusted host in place.
    const { session } = await connectGuest(host, hostId);
    expect(session).toBe(1);

    const rows = await runInDurableObject(stub(hostId), (_, state) =>
      state.storage.sql.exec("SELECT * FROM host").toArray(),
    );
    const expected = new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(secret)));
    expect(rows).toHaveLength(1);
    expect(new Uint8Array(rows[0].secret_sha256 as ArrayBuffer)).toEqual(expected);
    const stored = JSON.stringify(rows, (_, v) => (v instanceof ArrayBuffer ? Array.from(new Uint8Array(v)) : v));
    expect(stored).not.toContain(secret);
  });

  it("refuses missing or malformed credentials without trusting them", async () => {
    const hostId = newHostId();
    await expectError(await hostRequest(hostId), 401, "unauthorized");
    await expectError(await hostRequest(hostId, "Bearer short"), 401, "unauthorized");
    await expectError(await hostRequest(hostId, `Basic ${newSecret()}`), 401, "unauthorized");
    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}x`), 401, "unauthorized");

    // Nothing was trusted by those attempts: the first well-formed secret still wins.
    const secret = newSecret();
    await connectHost(hostId, secret);
    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}`), 401, "unauthorized");
  });

  it("keeps separate trust per host id", async () => {
    const [a, b] = [newHostId(), newHostId()];
    const secret = newSecret();
    await connectHost(a, secret);
    await connectHost(b, newSecret());
    await expectError(await hostRequest(b, `Bearer ${secret}`), 401, "unauthorized");
  });

  it("replaces the host socket with a newer authenticated one", async () => {
    const hostId = newHostId();
    const secret = newSecret();
    const old = await connectHost(hostId, secret);
    const { guest, session } = await connectGuest(old, hostId);

    const current = await connectHost(hostId, secret);
    expect(await old.closed).toEqual({ code: 4000, reason: "replaced" });
    // Sessions belonged to the old socket; the new host never heard of them.
    expect(await guest.closed).toEqual({ code: 1001, reason: "host_offline" });

    const next = await connectGuest(current, hostId);
    expect(next.session).toBeGreaterThan(session);
    current.send(frame(DATA, next.session, utf8("hello")));
    expect(text(new Uint8Array((await next.guest.next()) as ArrayBuffer))).toBe("hello");
  });
});

describe("guest sessions", () => {
  it("answers host_offline before any upgrade when no host is connected", async () => {
    const hostId = newHostId();
    await expectError(await guestRequest(hostId), 503, "host_offline");

    const host = await connectHost(hostId, newSecret());
    await connectGuest(host, hostId);
    host.ws.close(1000, "bye");
    await host.closed;
    await expectError(await guestRequest(hostId), 503, "host_offline");
  });

  it("routes two concurrent guests to their own sessions", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const a = await connectGuest(host, hostId);
    const b = await connectGuest(host, hostId);
    expect(b.session).toBeGreaterThan(a.session);

    host.send(frame(DATA, b.session, utf8("to-b")));
    host.send(frame(DATA, a.session, utf8("to-a")));
    expect(text(new Uint8Array((await a.guest.next()) as ArrayBuffer))).toBe("to-a");
    expect(text(new Uint8Array((await b.guest.next()) as ArrayBuffer))).toBe("to-b");

    b.guest.send(utf8("from-b"));
    a.guest.send(utf8("from-a"));
    const first = await host.nextFrame();
    const second = await host.nextFrame();
    expect([first.type, first.session, text(first.payload)]).toEqual([DATA, b.session, "from-b"]);
    expect([second.type, second.session, text(second.payload)]).toEqual([DATA, a.session, "from-a"]);
  });

  it("answers a text ping with pong on both sockets", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest } = await connectGuest(host, hostId);
    host.send("ping");
    expect(await host.next()).toBe("pong");
    guest.send("ping");
    expect(await guest.next()).toBe("pong");
  });

  it("wraps session ids after the largest u32", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    await runInDurableObject(stub(hostId), (_, state) => {
      state.storage.sql.exec("UPDATE host SET next_session = 4294967295");
    });
    expect((await connectGuest(host, hostId)).session).toBe(0xffff_ffff);
    expect((await connectGuest(host, hostId)).session).toBe(1);
  });

  it("keeps routing and numbering sessions after the object hibernates", async () => {
    const hostId = newHostId();
    const secret = newSecret();
    const host = await connectHost(hostId, secret);
    const a = await connectGuest(host, hostId);

    await evictDurableObject(stub(hostId));

    host.send(frame(DATA, a.session, utf8("after")));
    expect(text(new Uint8Array((await a.guest.next()) as ArrayBuffer))).toBe("after");
    a.guest.send(utf8("back"));
    const data = await host.nextFrame();
    expect([data.type, data.session, text(data.payload)]).toEqual([DATA, a.session, "back"]);
    expect((await connectGuest(host, hostId)).session).toBe(a.session + 1);
    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}`), 401, "unauthorized");
  });
});

describe("close propagation", () => {
  it("sends the host CLOSE when a guest closes", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);
    guest.ws.close(1000, "done");
    const close = await host.nextFrame();
    expect([close.type, close.session, close.payload.byteLength]).toEqual([CLOSE, session, 0]);
    expect((await guest.closed).code).toBe(1000);
  });

  it("closes the guest with the host's reason when the host sends CLOSE", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const a = await connectGuest(host, hostId);
    const b = await connectGuest(host, hostId);

    host.send(frame(CLOSE, a.session, utf8("invite_used")));
    expect(await a.guest.closed).toEqual({ code: 1000, reason: "invite_used" });
    // DATA for the closed session is dropped; the other session is untouched.
    host.send(frame(DATA, a.session, utf8("late")));
    host.send(frame(DATA, b.session, utf8("still here")));
    expect(text(new Uint8Array((await b.guest.next()) as ArrayBuffer))).toBe("still here");
    // The relay echoes no CLOSE for a session the host closed: the next frame is the new OPEN.
    const c = await connectGuest(host, hostId);
    expect(c.session).toBeGreaterThan(b.session);
  });

  it("closes the guest without a reason when the host's reason is too long", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);
    host.send(frame(CLOSE, session, utf8("x".repeat(124))));
    expect(await guest.closed).toEqual({ code: 1000, reason: "" });
  });

  it("closes every guest with 1001 when the host goes away", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const a = await connectGuest(host, hostId);
    const b = await connectGuest(host, hostId);
    host.ws.close(1000, "restart");
    expect(await a.guest.closed).toEqual({ code: 1001, reason: "host_offline" });
    expect(await b.guest.closed).toEqual({ code: 1001, reason: "host_offline" });
  });
});

describe("limits", () => {
  it("forwards a 70000-byte guest message and closes a bigger one with 1009", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);

    guest.send(new Uint8Array(MAX_MESSAGE).fill(7));
    const data = await host.nextFrame();
    expect([data.type, data.session, data.payload.byteLength]).toEqual([DATA, session, MAX_MESSAGE]);

    guest.send(new Uint8Array(MAX_MESSAGE + 1));
    expect((await guest.closed).code).toBe(1009);
    const close = await host.nextFrame();
    expect([close.type, close.session]).toEqual([CLOSE, session]);
  });

  it("forwards a 70000-byte host message and closes a bigger one with 1009", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);

    host.send(frame(DATA, session, new Uint8Array(MAX_MESSAGE - 5).fill(9)));
    expect(((await guest.next()) as ArrayBuffer).byteLength).toBe(MAX_MESSAGE - 5);

    host.send(frame(DATA, session, new Uint8Array(MAX_MESSAGE - 4)));
    expect((await host.closed).code).toBe(1009);
    expect(await guest.closed).toEqual({ code: 1001, reason: "host_offline" });
    await expectError(await guestRequest(hostId), 503, "host_offline");
  });

  it("caps a host at 32 open sessions", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const guests: GuestSession[] = [];
    for (let i = 0; i < 32; i++) guests.push(await connectGuest(host, hostId));

    await expectError(await guestRequest(hostId), 503, "host_busy");

    guests[0].guest.ws.close(1000, "done");
    expect((await host.nextFrame()).type).toBe(CLOSE);
    const admitted = await connectGuest(host, hostId);
    expect(admitted.session).toBe(guests[31].session + 1);
  });

  it("limits guest connects to 30 per minute per IP", async () => {
    const hostId = newHostId();
    const ip = freshIp();
    // With no host, each connect that passes the limiter gets host_offline.
    for (let i = 0; i < 30; i++) await expectError(await guestRequest(hostId, ip), 503, "host_offline");
    await expectError(await guestRequest(hostId, ip), 429, "rate_limited");
    await expectError(await guestRequest(hostId, freshIp()), 503, "host_offline");
  });

  it("closes a guest that sends text with 1003 and tells the host", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);
    guest.send("hello");
    expect((await guest.closed).code).toBe(1003);
    const close = await host.nextFrame();
    expect([close.type, close.session]).toEqual([CLOSE, session]);
  });

  it.each([
    ["text", "hello", 1003],
    ["a frame shorter than its header", new Uint8Array([DATA, 0, 0, 1]).buffer, 1002],
    ["an OPEN frame", frame(OPEN, 1), 1002],
    ["an unknown frame type", frame(0x7f, 1), 1002],
  ])("drops a host that sends %s", async (_, message, code) => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest } = await connectGuest(host, hostId);
    host.send(message);
    expect((await host.closed).code).toBe(code);
    expect(await guest.closed).toEqual({ code: 1001, reason: "host_offline" });
  });
});

describe("logging", () => {
  let lines: string[];

  beforeEach(() => {
    lines = [];
    for (const method of ["log", "info", "warn", "error", "debug"] as const) {
      vi.spyOn(console, method).mockImplementation((...args: unknown[]) => {
        lines.push(args.map(String).join(" "));
      });
    }
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("logs only endpoint, outcome and close code", async () => {
    const hostId = newHostId();
    const secret = newSecret();
    const marker = "PLAINTEXT-MARKER-4d2c";
    const host = await connectHost(hostId, secret);
    await hostRequest(hostId, `Bearer ${newSecret()}`);
    const { guest, session } = await connectGuest(host, hostId);
    guest.send(utf8(`guest says ${marker}`));
    await host.nextFrame();
    host.send(frame(DATA, session, utf8(`host says ${marker}`)));
    await guest.next();
    guest.send(new Uint8Array(MAX_MESSAGE + 1).fill(0x41));
    await guest.closed;
    expect((await host.nextFrame()).type).toBe(CLOSE);
    const second = await connectGuest(host, hostId);
    host.send(frame(CLOSE, second.session, utf8(`reason ${marker}`)));
    await second.guest.closed;
    host.ws.close(1000, `bye ${marker}`);
    await host.closed;
    await guestRequest(hostId);

    const outcomes = lines.map((line) => {
      const parsed = JSON.parse(line) as Record<string, unknown>;
      expect(Object.keys(parsed).every((key) => ["endpoint", "outcome", "code"].includes(key))).toBe(true);
      return `${parsed.endpoint} ${parsed.outcome}`;
    });
    expect(outcomes).toEqual(
      expect.arrayContaining([
        "/v1/host enrolled",
        "/v1/host unauthorized",
        "/v1/guest opened",
        "/v1/guest message_too_big",
        "/v1/guest closed",
        "/v1/host closed",
        "/v1/guest host_offline",
      ]),
    );
    const all = lines.join("\n");
    for (const secretText of [hostId, secret, marker]) expect(all).not.toContain(secretText);
  });
});
