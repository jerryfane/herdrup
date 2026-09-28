// herdrup-guest: the relay between a guest's HerdrUp app and the host daemon that runs
// the shared agent (herdrup#309). One Durable Object per host_id pipes Noise_IK
// ciphertext between the host socket and its guest sockets, so it never sees plaintext.
// Log lines carry only endpoint, outcome and close code: never payloads, secrets or host ids.

export const VERSION = "1.0.0";

export interface Env {
  HOSTS: DurableObjectNamespace;
  GUEST_CONNECT_LIMIT?: RateLimit;
}

export type Endpoint = "/v1/host" | "/v1/guest";

export interface LogLine {
  endpoint: Endpoint;
  outcome: string;
  code?: number;
}

export function log(line: LogLine): void {
  console.log(JSON.stringify(line));
}

// host_id is b64url of 16 bytes: 22 characters.
const SOCKET_PATH = /^\/v1\/(host|guest)\/[A-Za-z0-9_-]{22}$/;

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (request.method === "GET" && pathname === "/v1/health") {
    return json(200, { ok: true, version: VERSION });
  }
  const match = request.method === "GET" ? SOCKET_PATH.exec(pathname) : null;
  if (match === null) return errorResponse(404, "not_found");

  const endpoint: Endpoint = match[1] === "host" ? "/v1/host" : "/v1/guest";
  try {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      log({ endpoint, outcome: "upgrade_required" });
      return errorResponse(426, "upgrade_required", { Upgrade: "websocket" });
    }
    if (endpoint === "/v1/guest") {
      const limiter = env.GUEST_CONNECT_LIMIT;
      if (limiter === undefined) {
        log({ endpoint, outcome: "not_configured" });
        return errorResponse(500, "not_configured");
      }
      const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
      if (!(await limiter.limit({ key: ip })).success) {
        log({ endpoint, outcome: "rate_limited" });
        return errorResponse(429, "rate_limited");
      }
    }
    const hostId = pathname.slice(pathname.lastIndexOf("/") + 1);
    return await env.HOSTS.get(env.HOSTS.idFromName(hostId)).fetch(request);
  } catch {
    // The error itself is deliberately not logged: it may echo request content.
    log({ endpoint, outcome: "internal_error" });
    return errorResponse(500, "internal_error");
  }
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

/**
 * An error before the WebSocket upgrade. The code also goes in X-Herdr-Guest-Error, because
 * URLSessionWebSocketTask cannot read the body of a failed upgrade.
 */
export function errorResponse(status: number, code: string, headers: Record<string, string> = {}): Response {
  return json(status, { error: code }, { ...headers, "X-Herdr-Guest-Error": code });
}
