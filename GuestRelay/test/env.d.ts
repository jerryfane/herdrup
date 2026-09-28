declare namespace Cloudflare {
  interface Env {
    HOSTS: DurableObjectNamespace;
    GUEST_CONNECT_LIMIT: RateLimit;
    HOST_CONNECT_LIMIT: RateLimit;
    ASSETS: Fetcher;
  }
}
