// herdrup-push: the publisher-run APNs relay for App Store builds (herdrup#277).
// The app enrolls a push token and gets back a sealed capability; the daemon later
// hands that capability plus a payload to /v1/send and the relay signs the APNs call
// with the publisher key. Message text transits this Worker but is never stored or
// logged: log lines carry only endpoint, outcome, APNs status and reason.

export const VERSION = "1.0.0";

const ALERT_TOPIC = "com.jerryfane.herdr";
const LIVE_ACTIVITY_TOPIC = "com.jerryfane.herdr.push-type.liveactivity";
const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

const CAPABILITY_PREFIX = "hpr1.";
const SEAL_AAD = new TextEncoder().encode("hpr1");
const NONCE_BYTES = 12;
const GCM_TAG_BYTES = 16;

const ENROLL_BODY_MAX = 2 * 1024;
const SEND_BODY_MAX = 8 * 1024;
const PAYLOAD_MAX = 4096;
const COLLAPSE_ID_MAX = 64;
const JWT_MAX_AGE_SECONDS = 50 * 60;

export type Kind = "device" | "activity";
export type Environment = "production" | "sandbox";
export type PushType = "alert" | "liveactivity";

export interface RateLimit {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  RELAY_SEAL_KEY?: string;
  ENROLL_LIMIT?: RateLimit;
  SEND_LIMIT?: RateLimit;
}

export interface CapabilityClaims {
  v: 1;
  k: Kind;
  t: string;
  e: Environment;
  iat: number;
}

export interface LogLine {
  endpoint: string;
  outcome: string;
  status?: number;
  reason?: string | null;
}

export interface Deps {
  fetch: typeof fetch;
  /** Unix seconds. */
  now: () => number;
  log: (line: LogLine) => void;
}

class NotConfigured extends Error {}

export async function handleRequest(request: Request, env: Env, deps: Deps): Promise<Response> {
  const { pathname } = new URL(request.url);
  const endpoint = pathname;
  try {
    if (request.method === "GET" && pathname === "/v1/health") {
      return json(200, { ok: true, version: VERSION });
    }
    if (request.method === "POST" && pathname === "/v1/enroll") {
      return await enroll(request, env, deps);
    }
    if (request.method === "POST" && pathname === "/v1/send") {
      return await send(request, env, deps);
    }
    return json(404, { error: "not_found" });
  } catch (err) {
    // The error itself is deliberately not logged: it may echo request content.
    if (err instanceof NotConfigured) {
      deps.log({ endpoint, outcome: "not_configured" });
      return json(500, { error: "not_configured" });
    }
    deps.log({ endpoint, outcome: "internal_error" });
    return json(500, { error: "internal_error" });
  }
}

// ---------------------------------------------------------------- enroll

async function enroll(request: Request, env: Env, deps: Deps): Promise<Response> {
  const endpoint = "/v1/enroll";
  const limiter = requireBinding(env.ENROLL_LIMIT);
  const sealKey = await sealKeyFrom(env.RELAY_SEAL_KEY);

  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await limiter.limit({ key: ip })).success) {
    deps.log({ endpoint, outcome: "rate_limited" });
    return json(429, { error: "rate_limited" });
  }

  const bad = (detail: string) => {
    deps.log({ endpoint, outcome: "invalid_request" });
    return json(400, { error: "invalid_request", detail });
  };

  const body = await readJsonCapped(request, ENROLL_BODY_MAX);
  if (body === TOO_LARGE) return bad("body exceeds 2048 bytes");
  if (!isObject(body)) return bad("body must be a JSON object");

  const { kind, token, environment } = body;
  if (kind !== "device" && kind !== "activity") return bad("kind must be device or activity");
  if (environment !== "production" && environment !== "sandbox") {
    return bad("environment must be production or sandbox");
  }
  if (typeof token !== "string" || !validToken(kind, token)) {
    return bad(kind === "device" ? "token must be 64-200 hex chars" : "token must be 32-512 hex chars");
  }

  const capability = await sealCapability(sealKey, {
    v: 1,
    k: kind,
    t: token.toLowerCase(),
    e: environment,
    iat: deps.now(),
  });
  deps.log({ endpoint, outcome: "ok" });
  return json(200, { capability });
}

export function validToken(kind: Kind, token: string): boolean {
  const [min, max] = kind === "device" ? [64, 200] : [32, 512];
  return token.length >= min && token.length <= max && /^[0-9a-fA-F]+$/.test(token);
}

// ---------------------------------------------------------------- send

async function send(request: Request, env: Env, deps: Deps): Promise<Response> {
  const endpoint = "/v1/send";
  const limiter = requireBinding(env.SEND_LIMIT);
  const sealKey = await sealKeyFrom(env.RELAY_SEAL_KEY);
  const keyId = requireSecret(env.APNS_KEY_ID);
  const teamId = requireSecret(env.APNS_TEAM_ID);
  const p8 = requireSecret(env.APNS_KEY_P8);

  const bad = (detail: string) => {
    deps.log({ endpoint, outcome: "invalid_request" });
    return json(400, { error: "invalid_request", detail });
  };
  const tooLarge = () => {
    deps.log({ endpoint, outcome: "payload_too_large" });
    return json(400, { error: "payload_too_large" });
  };

  const body = await readJsonCapped(request, SEND_BODY_MAX);
  if (body === TOO_LARGE) return tooLarge();
  if (!isObject(body)) return bad("body must be a JSON object");
  if (typeof body.capability !== "string") return bad("capability must be a string");

  if (!(await limiter.limit({ key: await sha256Hex(body.capability) })).success) {
    deps.log({ endpoint, outcome: "rate_limited" });
    return json(429, { error: "rate_limited" });
  }

  const claims = await openCapability(sealKey, body.capability);
  if (!claims) {
    deps.log({ endpoint, outcome: "invalid_capability" });
    return json(400, { error: "invalid_capability" });
  }

  const { push_type: pushType, priority, expiration, collapse_id: collapseId, payload } = body;
  if (pushType !== "alert" && pushType !== "liveactivity") {
    return bad("push_type must be alert or liveactivity");
  }
  if (claims.k !== (pushType === "alert" ? "device" : "activity")) {
    return bad("push_type does not match the capability kind");
  }
  if (priority !== 10 && priority !== 5) return bad("priority must be 10 or 5");
  if (expiration !== undefined && !(Number.isSafeInteger(expiration) && (expiration as number) >= 0)) {
    return bad("expiration must be unix seconds");
  }
  if (
    collapseId !== undefined &&
    (typeof collapseId !== "string" || new TextEncoder().encode(collapseId).length > COLLAPSE_ID_MAX)
  ) {
    return bad("collapse_id must be a string of at most 64 bytes");
  }
  if (!isObject(payload) || !isObject(payload.aps)) return bad("payload must be an object with an aps object");
  const payloadJson = JSON.stringify(payload);
  if (new TextEncoder().encode(payloadJson).length > PAYLOAD_MAX) return tooLarge();

  const headers: Record<string, string> = {
    authorization: `bearer ${await apnsJwt(p8, keyId, teamId, deps.now())}`,
    "content-type": "application/json",
    "apns-topic": pushType === "alert" ? ALERT_TOPIC : LIVE_ACTIVITY_TOPIC,
    "apns-push-type": pushType,
    "apns-priority": String(priority),
  };
  if (expiration !== undefined) headers["apns-expiration"] = String(expiration);
  if (collapseId !== undefined) headers["apns-collapse-id"] = collapseId as string;

  let apns: Response;
  try {
    apns = await deps.fetch(`${APNS_HOSTS[claims.e]}/3/device/${claims.t}`, {
      method: "POST",
      headers,
      body: payloadJson,
    });
  } catch {
    deps.log({ endpoint, outcome: "apns_unreachable" });
    return json(502, { status: 0, reason: null });
  }

  if (apns.status === 200) {
    deps.log({ endpoint, outcome: "ok", status: 200 });
    return json(200, { status: 200, apns_id: apns.headers.get("apns-id") });
  }
  const reason = await apnsReason(apns);
  if (apns.status === 410 || (apns.status === 400 && reason === "BadDeviceToken")) {
    deps.log({ endpoint, outcome: "gone", status: apns.status, reason });
    return json(410, { status: apns.status, reason });
  }
  deps.log({ endpoint, outcome: "apns_error", status: apns.status, reason });
  return json(502, { status: apns.status, reason });
}

async function apnsReason(response: Response): Promise<string | null> {
  try {
    const body: unknown = await response.json();
    return isObject(body) && typeof body.reason === "string" ? body.reason : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- sealed capability

export async function importSealKey(base64Key: string): Promise<CryptoKey> {
  const raw = base64Decode(base64Key);
  if (!raw || raw.length !== 32) throw new NotConfigured();
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

export async function sealCapability(key: CryptoKey, claims: CapabilityClaims): Promise<string> {
  const nonce = crypto.getRandomValues(new Uint8Array(NONCE_BYTES));
  const plaintext = new TextEncoder().encode(JSON.stringify(claims));
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: SEAL_AAD }, key, plaintext),
  );
  const out = new Uint8Array(NONCE_BYTES + sealed.length);
  out.set(nonce);
  out.set(sealed, NONCE_BYTES);
  return CAPABILITY_PREFIX + base64UrlEncode(out);
}

/** Returns null for anything that is not an intact, well-formed capability. */
export async function openCapability(key: CryptoKey, capability: string): Promise<CapabilityClaims | null> {
  if (!capability.startsWith(CAPABILITY_PREFIX)) return null;
  const bytes = base64UrlDecode(capability.slice(CAPABILITY_PREFIX.length));
  if (!bytes || bytes.length < NONCE_BYTES + GCM_TAG_BYTES) return null;
  let plaintext: ArrayBuffer;
  try {
    plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes.subarray(0, NONCE_BYTES), additionalData: SEAL_AAD },
      key,
      bytes.subarray(NONCE_BYTES),
    );
  } catch {
    return null;
  }
  let claims: unknown;
  try {
    claims = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plaintext));
  } catch {
    return null;
  }
  if (
    !isObject(claims) ||
    claims.v !== 1 ||
    (claims.k !== "device" && claims.k !== "activity") ||
    (claims.e !== "production" && claims.e !== "sandbox") ||
    typeof claims.t !== "string" ||
    !/^[0-9a-f]+$/.test(claims.t) ||
    !Number.isSafeInteger(claims.iat)
  ) {
    return null;
  }
  return claims as unknown as CapabilityClaims;
}

// ---------------------------------------------------------------- APNs provider token

let jwtCache: { token: string; iat: number; keyId: string; teamId: string } | null = null;
let signingKeyCache: { pem: string; key: CryptoKey } | null = null;

/** Test hook: forget the per-isolate JWT and signing key. */
export function resetJwtCache(): void {
  jwtCache = null;
  signingKeyCache = null;
}

/** ES256 provider token, reused per isolate for up to 50 minutes. */
export async function apnsJwt(pem: string, keyId: string, teamId: string, now: number): Promise<string> {
  if (
    jwtCache &&
    jwtCache.keyId === keyId &&
    jwtCache.teamId === teamId &&
    now >= jwtCache.iat &&
    now - jwtCache.iat < JWT_MAX_AGE_SECONDS
  ) {
    return jwtCache.token;
  }
  const key = await signingKey(pem);
  const encode = (value: object) => base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
  const signingInput = `${encode({ alg: "ES256", kid: keyId })}.${encode({ iss: teamId, iat: now })}`;
  // WebCrypto ECDSA already yields the raw r||s (64 bytes) form JWS requires.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  const token = `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
  jwtCache = { token, iat: now, keyId, teamId };
  return token;
}

async function signingKey(pem: string): Promise<CryptoKey> {
  if (signingKeyCache?.pem === pem) return signingKeyCache.key;
  const der = base64Decode(pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, ""));
  if (!der) throw new NotConfigured();
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  } catch {
    throw new NotConfigured();
  }
  signingKeyCache = { pem, key };
  return key;
}

// ---------------------------------------------------------------- helpers

function requireSecret(value: string | undefined): string {
  if (!value || !value.trim()) throw new NotConfigured();
  return value.trim();
}

function requireBinding(binding: RateLimit | undefined): RateLimit {
  if (!binding) throw new NotConfigured();
  return binding;
}

let sealKeyCache: { secret: string; key: CryptoKey } | null = null;

async function sealKeyFrom(secret: string | undefined): Promise<CryptoKey> {
  const value = requireSecret(secret);
  if (sealKeyCache?.secret === value) return sealKeyCache.key;
  const key = await importSealKey(value);
  sealKeyCache = { secret: value, key };
  return key;
}

const TOO_LARGE = Symbol("too_large");

/** Reads at most `max` bytes; returns TOO_LARGE past that, undefined for non-JSON. */
async function readJsonCapped(request: Request, max: number): Promise<unknown> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) return TOO_LARGE;
  const bytes = new Uint8Array(max);
  let length = 0;
  if (request.body) {
    const reader = request.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (length + value.length > max) {
        await reader.cancel();
        return TOO_LARGE;
      }
      bytes.set(value, length);
      length += value.length;
    }
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, length)));
  } catch {
    return undefined;
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function sha256Hex(text: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(text: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  return base64Decode(text.replace(/-/g, "+").replace(/_/g, "/"));
}

function base64Decode(text: string): Uint8Array<ArrayBuffer> | null {
  try {
    const padded = text + "=".repeat((4 - (text.length % 4)) % 4);
    return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}
