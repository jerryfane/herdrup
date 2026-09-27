import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  base64UrlEncode,
  handleRequest,
  importSealKey,
  openCapability,
  MAX_CAPABILITY_LENGTH,
  resetJwtCache,
  sealCapability,
  TOKEN_HEX_BOUNDS,
  type Deps,
  type Env,
  type LogLine,
  type RateLimit,
} from "../src/relay";

const DEVICE_TOKEN = "AB".repeat(32);
const ACTIVITY_TOKEN = "cd".repeat(40);
const NOW = 1_800_000_000;
const SECRET_TEXT = "the secret agent message";

interface Harness {
  env: Env;
  deps: Deps;
  logs: LogLine[];
  apnsCalls: { url: string; init: RequestInit }[];
  limiterKeys: { enroll: string[]; send: string[] };
  publicKey: CryptoKey;
  pem: string;
  sealKeyB64: string;
  apnsResponse: () => Response;
  clock: { now: number };
}

function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function limiter(keys: string[], success = true): RateLimit {
  return {
    async limit({ key }) {
      keys.push(key);
      return { success };
    },
  };
}

async function harness(): Promise<Harness> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64(der).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  const sealKeyB64 = b64(crypto.getRandomValues(new Uint8Array(32)));
  const limiterKeys = { enroll: [] as string[], send: [] as string[] };
  const h: Harness = {
    env: {
      APNS_KEY_P8: pem,
      APNS_KEY_ID: "KEYID12345",
      APNS_TEAM_ID: "TEAMID6789",
      RELAY_SEAL_KEY: sealKeyB64,
      ENROLL_LIMIT: limiter(limiterKeys.enroll),
      SEND_LIMIT: limiter(limiterKeys.send),
    },
    logs: [],
    apnsCalls: [],
    limiterKeys,
    publicKey: pair.publicKey,
    pem,
    sealKeyB64,
    clock: { now: NOW },
    apnsResponse: () => new Response(null, { status: 200, headers: { "apns-id": "11111111-2222-3333-4444-555555555555" } }),
    deps: undefined as unknown as Deps,
  };
  h.deps = {
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      h.apnsCalls.push({ url: String(input), init: init ?? {} });
      return h.apnsResponse();
    }) as typeof fetch,
    now: () => h.clock.now,
    log: (line) => h.logs.push(line),
  };
  return h;
}

async function call(h: Harness, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  const request = new Request(`https://push.example${path}`, {
    method,
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
  const response = await handleRequest(request, h.env, h.deps);
  return { status: response.status, body: (await response.json()) as Record<string, unknown> };
}

async function enroll(h: Harness, kind: "device" | "activity", token: string, environment = "production") {
  const res = await call(h, "POST", "/v1/enroll", { kind, token, environment }, { "CF-Connecting-IP": "203.0.113.7" });
  expect(res.status).toBe(200);
  return res.body.capability as string;
}

function alertPayload(body = SECRET_TEXT) {
  return { aps: { alert: { title: "herdr", body } }, pane: "p1" };
}

async function send(h: Harness, fields: Record<string, unknown>) {
  return call(h, "POST", "/v1/send", fields);
}

let h: Harness;
beforeEach(async () => {
  resetJwtCache();
  h = await harness();
});
afterEach(() => vi.restoreAllMocks());

describe("sealed capability", () => {
  it("round-trips the claims through seal and open", async () => {
    const key = await importSealKey(h.sealKeyB64);
    const claims = { v: 1, k: "activity", t: "abcdef0123456789abcdef0123456789", e: "sandbox", iat: NOW } as const;
    const capability = await sealCapability(key, claims);
    expect(capability).toMatch(/^hpr1\.[A-Za-z0-9_-]+$/);
    expect(await openCapability(key, capability)).toEqual(claims);
  });

  it("enroll lowercases the token and seals kind, environment and iat", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN, "sandbox");
    const claims = await openCapability(await importSealKey(h.sealKeyB64), capability);
    expect(claims).toEqual({ v: 1, k: "device", t: DEVICE_TOKEN.toLowerCase(), e: "sandbox", iat: NOW });
  });

  it("rejects a tampered capability, a foreign key, and garbage", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    const body = capability.slice(5);
    const flipped = body[20] === "A" ? "B" : "A";
    const tampered = `hpr1.${body.slice(0, 20)}${flipped}${body.slice(21)}`;
    const foreign = await sealCapability(await importSealKey(b64(new Uint8Array(32).fill(7))), {
      v: 1,
      k: "device",
      t: DEVICE_TOKEN.toLowerCase(),
      e: "production",
      iat: NOW,
    });
    for (const bad of [tampered, foreign, "hpr1.", "hpr1.!!!", `hpr2.${body}`, "nonsense"]) {
      const res = await send(h, { capability: bad, push_type: "alert", priority: 10, payload: alertPayload() });
      expect(res).toEqual({ status: 400, body: { error: "invalid_capability" } });
    }
    expect(h.apnsCalls).toHaveLength(0);
  });

  it("keeps the longest accepted token's capability within the daemons' 512-character limit", async () => {
    // A daemon refuses a longer capability and with it the whole registration, silently.
    for (const kind of ["device", "activity"] as const) {
      const [, max] = TOKEN_HEX_BOUNDS[kind];
      const capability = await enroll(h, kind, "f".repeat(max), "production");
      expect(capability.length).toBeLessThanOrEqual(MAX_CAPABILITY_LENGTH);
    }
  });

  it("rejects an authentic capability whose claims are malformed", async () => {
    const key = await importSealKey(h.sealKeyB64);
    const bad = await sealCapability(key, { v: 1, k: "device", t: "NOT-HEX", e: "production", iat: NOW });
    expect(await openCapability(key, bad)).toBeNull();
  });
});

describe("enroll validation", () => {
  it.each([
    ["device", "a".repeat(63)],
    ["device", "a".repeat(201)],
    ["device", "g".repeat(64)],
    ["activity", "a".repeat(31)],
    ["activity", "a".repeat(257)],
    ["activity", ""],
  ])("rejects %s token %s", async (kind, token) => {
    const res = await call(h, "POST", "/v1/enroll", { kind, token, environment: "production" });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe("invalid_request");
  });

  it.each([
    ["device", 64],
    ["device", 200],
    ["activity", 32],
    ["activity", 256],
  ])("accepts %s token at boundary length %i", async (kind, length) => {
    const res = await call(h, "POST", "/v1/enroll", { kind, token: "F".repeat(length), environment: "production" });
    expect(res.status).toBe(200);
  });

  it("rejects an unknown kind or environment and non-object bodies", async () => {
    for (const body of [
      { kind: "watch", token: DEVICE_TOKEN, environment: "production" },
      { kind: "device", token: DEVICE_TOKEN, environment: "staging" },
      { kind: "device", token: 42, environment: "production" },
      "[1,2]",
      "{not json",
    ]) {
      const res = await call(h, "POST", "/v1/enroll", body);
      expect(res.status).toBe(400);
      expect(res.body.error).toBe("invalid_request");
    }
  });

  it("rejects an enroll body over 2 KB", async () => {
    const body = JSON.stringify({ kind: "device", token: DEVICE_TOKEN, environment: "production", pad: "x".repeat(2048) });
    const res = await call(h, "POST", "/v1/enroll", body);
    expect(res.status).toBe(400);
    expect(res.body.error).toBe("invalid_request");
  });
});

describe("send", () => {
  it("returns 200 with the apns-id and posts the payload to the production host", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    const payload = alertPayload();
    const res = await send(h, { capability, push_type: "alert", priority: 10, payload });
    expect(res).toEqual({ status: 200, body: { status: 200, apns_id: "11111111-2222-3333-4444-555555555555" } });
    expect(h.apnsCalls).toHaveLength(1);
    expect(h.apnsCalls[0].url).toBe(`https://api.push.apple.com/3/device/${DEVICE_TOKEN.toLowerCase()}`);
    expect(h.apnsCalls[0].init.method).toBe("POST");
    expect(JSON.parse(h.apnsCalls[0].init.body as string)).toEqual(payload);
  });

  it("uses the sandbox host for sandbox capabilities", async () => {
    const capability = await enroll(h, "activity", ACTIVITY_TOKEN, "sandbox");
    await send(h, { capability, push_type: "liveactivity", priority: 5, payload: { aps: { event: "update" } } });
    expect(h.apnsCalls[0].url).toBe(`https://api.sandbox.push.apple.com/3/device/${ACTIVITY_TOKEN}`);
  });

  it("sets the alert topic and headers, including optional expiration and collapse id", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    await send(h, {
      capability,
      push_type: "alert",
      priority: 10,
      expiration: NOW + 3600,
      collapse_id: "pane-1",
      payload: alertPayload(),
    });
    const headers = h.apnsCalls[0].init.headers as Record<string, string>;
    expect(headers["apns-topic"]).toBe("com.jerryfane.herdr");
    expect(headers["apns-push-type"]).toBe("alert");
    expect(headers["apns-priority"]).toBe("10");
    expect(headers["apns-expiration"]).toBe(String(NOW + 3600));
    expect(headers["apns-collapse-id"]).toBe("pane-1");
    expect(headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  });

  it("sets the live activity topic and omits absent optional headers", async () => {
    const capability = await enroll(h, "activity", ACTIVITY_TOKEN);
    await send(h, { capability, push_type: "liveactivity", priority: 5, payload: { aps: { event: "update" } } });
    const headers = h.apnsCalls[0].init.headers as Record<string, string>;
    expect(headers["apns-topic"]).toBe("com.jerryfane.herdr.push-type.liveactivity");
    expect(headers["apns-push-type"]).toBe("liveactivity");
    expect(headers["apns-priority"]).toBe("5");
    expect(headers).not.toHaveProperty("apns-expiration");
    expect(headers).not.toHaveProperty("apns-collapse-id");
  });

  it("rejects a push_type that does not match the capability kind", async () => {
    const device = await enroll(h, "device", DEVICE_TOKEN);
    const activity = await enroll(h, "activity", ACTIVITY_TOKEN);
    const a = await send(h, { capability: device, push_type: "liveactivity", priority: 5, payload: alertPayload() });
    const b = await send(h, { capability: activity, push_type: "alert", priority: 10, payload: alertPayload() });
    for (const res of [a, b]) {
      expect(res.status).toBe(400);
      expect(res.body.error).toBe("invalid_request");
    }
    expect(h.apnsCalls).toHaveLength(0);
  });

  it("rejects bad priority, expiration, collapse id and payload shapes", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    const base = { capability, push_type: "alert", priority: 10, payload: alertPayload() };
    for (const override of [
      { push_type: "background" },
      { priority: 1 },
      { priority: undefined },
      { expiration: -1 },
      { expiration: "soon" },
      { collapse_id: "x".repeat(65) },
      { collapse_id: "é".repeat(33) },
      { payload: { alert: "no aps" } },
      { payload: { aps: [] } },
      { payload: [] },
    ]) {
      const res = await send(h, { ...base, ...override });
      expect(res.status, JSON.stringify(override)).toBe(400);
      expect(res.body.error).toBe("invalid_request");
    }
    expect(h.apnsCalls).toHaveLength(0);
  });

  it("accepts a 4096-byte payload and rejects 4097 bytes with payload_too_large", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    const sized = (bytes: number) => {
      const payload = alertPayload("");
      const overhead = JSON.stringify(payload).length;
      return alertPayload("x".repeat(bytes - overhead));
    };
    const ok = await send(h, { capability, push_type: "alert", priority: 10, payload: sized(4096) });
    expect(ok.status).toBe(200);
    const big = await send(h, { capability, push_type: "alert", priority: 10, payload: sized(4097) });
    expect(big).toEqual({ status: 400, body: { error: "payload_too_large" } });
    expect(h.apnsCalls).toHaveLength(1);
  });

  it("rejects a send body over 8 KB", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    const res = await send(h, { capability, push_type: "alert", priority: 10, payload: alertPayload(), pad: "x".repeat(8192) });
    expect(res).toEqual({ status: 400, body: { error: "payload_too_large" } });
  });

  it.each([
    [410, { reason: "Unregistered" }, 410, "Unregistered"],
    [400, { reason: "BadDeviceToken" }, 410, "BadDeviceToken"],
    [400, { reason: "BadTopic" }, 502, "BadTopic"],
    [403, { reason: "InvalidProviderToken" }, 502, "InvalidProviderToken"],
    [429, { reason: "TooManyRequests" }, 502, "TooManyRequests"],
    [500, "<html>oops</html>", 502, null],
  ])("maps APNs %i %j to %i", async (apnsStatus, apnsBody, status, reason) => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    h.apnsResponse = () =>
      new Response(typeof apnsBody === "string" ? apnsBody : JSON.stringify(apnsBody), { status: apnsStatus });
    const res = await send(h, { capability, push_type: "alert", priority: 10, payload: alertPayload() });
    expect(res).toEqual({ status, body: { status: apnsStatus, reason } });
  });

  it("maps an unreachable APNs to 502", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    h.deps.fetch = async () => {
      throw new TypeError("network down");
    };
    const res = await send(h, { capability, push_type: "alert", priority: 10, payload: alertPayload() });
    expect(res.status).toBe(502);
  });
});

describe("APNs provider token", () => {
  function decodePart(part: string): Record<string, unknown> {
    return JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
  }

  async function sentJwt(): Promise<string> {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    await send(h, { capability, push_type: "alert", priority: 10, payload: alertPayload() });
    const headers = h.apnsCalls.at(-1)!.init.headers as Record<string, string>;
    return headers.authorization.slice("bearer ".length);
  }

  it("is an ES256 JWT with kid/iss/iat whose signature verifies with the public key", async () => {
    const jwt = await sentJwt();
    const [header, claims, signature] = jwt.split(".");
    expect(decodePart(header)).toEqual({ alg: "ES256", kid: "KEYID12345" });
    expect(decodePart(claims)).toEqual({ iss: "TEAMID6789", iat: NOW });
    const sig = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
    expect(sig).toHaveLength(64);
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      h.publicKey,
      sig,
      new TextEncoder().encode(`${header}.${claims}`),
    );
    expect(valid).toBe(true);
    expect(base64UrlEncode(sig)).toBe(signature);
  });

  it("re-signs at once when the .p8 is rotated under the same key id", async () => {
    const first = await sentJwt();
    const other = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
      "sign",
      "verify",
    ])) as CryptoKeyPair;
    const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", other.privateKey));
    h.env.APNS_KEY_P8 = `-----BEGIN PRIVATE KEY-----\n${b64(der).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
    const rotated = await sentJwt();
    expect(rotated).not.toBe(first);
    const [header, claims, signature] = rotated.split(".");
    const sig = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      other.publicKey,
      sig,
      new TextEncoder().encode(`${header}.${claims}`),
    );
    expect(valid).toBe(true);
  });

  it("reuses the token for under 50 minutes and re-signs after", async () => {
    const first = await sentJwt();
    h.clock.now = NOW + 50 * 60 - 1;
    expect(await sentJwt()).toBe(first);
    h.clock.now = NOW + 50 * 60;
    const refreshed = await sentJwt();
    expect(refreshed).not.toBe(first);
    expect(decodePart(refreshed.split(".")[1]).iat).toBe(NOW + 50 * 60);
  });
});

describe("rate limits", () => {
  it("returns 429 on enroll when ENROLL_LIMIT refuses, keyed by client IP", async () => {
    const keys: string[] = [];
    h.env.ENROLL_LIMIT = limiter(keys, false);
    const res = await call(h, "POST", "/v1/enroll", { kind: "device", token: DEVICE_TOKEN, environment: "production" }, {
      "CF-Connecting-IP": "198.51.100.9",
    });
    expect(res).toEqual({ status: 429, body: { error: "rate_limited" } });
    expect(keys).toEqual(["198.51.100.9"]);
  });

  it("returns 429 on send when SEND_LIMIT refuses, keyed by the capability's SHA-256", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    const keys: string[] = [];
    h.env.SEND_LIMIT = limiter(keys, false);
    const res = await send(h, { capability, push_type: "alert", priority: 10, payload: alertPayload() });
    expect(res).toEqual({ status: 429, body: { error: "rate_limited" } });
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(capability)));
    expect(keys).toEqual([Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("")]);
    expect(h.apnsCalls).toHaveLength(0);
  });
});

describe("configuration and routing", () => {
  it("serves health without any secrets", async () => {
    const res = await handleRequest(new Request("https://push.example/v1/health"), {}, h.deps);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, version: expect.any(String) });
  });

  it.each(["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID", "RELAY_SEAL_KEY", "SEND_LIMIT"] as const)(
    "send without %s is 500 not_configured",
    async (name) => {
      const capability = await enroll(h, "device", DEVICE_TOKEN);
      delete h.env[name];
      const res = await send(h, { capability, push_type: "alert", priority: 10, payload: alertPayload() });
      expect(res).toEqual({ status: 500, body: { error: "not_configured" } });
    },
  );

  it("malformed seal key or .p8 is 500 not_configured", async () => {
    const capability = await enroll(h, "device", DEVICE_TOKEN);
    h.env.APNS_KEY_P8 = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----";
    expect(await send(h, { capability, push_type: "alert", priority: 10, payload: alertPayload() })).toEqual({
      status: 500,
      body: { error: "not_configured" },
    });
    h.env.RELAY_SEAL_KEY = b64(new Uint8Array(16));
    expect(
      await call(h, "POST", "/v1/enroll", { kind: "device", token: DEVICE_TOKEN, environment: "production" }),
    ).toEqual({ status: 500, body: { error: "not_configured" } });
  });

  it.each([
    ["GET", "/v1/send"],
    ["GET", "/v1/enroll"],
    ["POST", "/v1/health"],
    ["GET", "/"],
    ["POST", "/v2/send"],
  ])("%s %s is 404", async (method, path) => {
    const res = await call(h, method, path, method === "GET" ? undefined : {});
    expect(res.status).toBe(404);
  });
});

describe("logging", () => {
  it("never logs tokens, capabilities, payload text or key material on any path", async () => {
    const consoleCalls: unknown[] = [];
    for (const method of ["log", "info", "warn", "error", "debug"] as const) {
      vi.spyOn(console, method).mockImplementation((...args) => consoleCalls.push(...args));
    }
    const device = await enroll(h, "device", DEVICE_TOKEN);
    const activity = await enroll(h, "activity", ACTIVITY_TOKEN);
    const send10 = (capability: string, extra: Record<string, unknown> = {}) =>
      send(h, { capability, push_type: "alert", priority: 10, payload: alertPayload(), ...extra });

    await send10(device);
    await send10(activity);
    await send10(`${device.slice(0, -2)}AA`);
    await send10(device, { payload: alertPayload(SECRET_TEXT.repeat(300)) });
    for (const [status, body] of [
      [410, { reason: "Unregistered" }],
      [400, { reason: "BadDeviceToken" }],
      [500, { reason: "InternalServerError" }],
    ] as const) {
      h.apnsResponse = () => new Response(JSON.stringify(body), { status });
      await send10(device);
    }
    h.deps.fetch = async () => {
      throw new Error(`boom ${SECRET_TEXT} ${DEVICE_TOKEN}`);
    };
    await send10(device);
    h.env.SEND_LIMIT = limiter([], false);
    await send10(device);
    await call(h, "POST", "/v1/enroll", { kind: "device", token: `${DEVICE_TOKEN}zz`, environment: "production" });
    delete h.env.APNS_KEY_P8;
    await send10(device);

    const logged = JSON.stringify([h.logs, consoleCalls]);
    for (const secret of [
      DEVICE_TOKEN,
      DEVICE_TOKEN.toLowerCase(),
      ACTIVITY_TOKEN,
      device,
      device.slice(5, 40),
      activity,
      SECRET_TEXT,
      h.sealKeyB64,
      h.pem.split("\n")[1],
    ]) {
      expect(logged).not.toContain(secret);
    }
    expect(consoleCalls).toEqual([]);
    for (const line of h.logs) {
      expect(Object.keys(line).every((k) => ["endpoint", "outcome", "status", "reason"].includes(k))).toBe(true);
    }
    expect(h.logs.map((l) => l.outcome)).toEqual(
      expect.arrayContaining(["ok", "invalid_request", "invalid_capability", "payload_too_large", "gone", "apns_error", "apns_unreachable", "rate_limited", "not_configured"]),
    );
  });
});
