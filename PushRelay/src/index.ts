// Worker entry point. Every named export of this module becomes a Workers
// entrypoint, so the relay logic and its test seams live in relay.ts.
import { handleRequest, type Deps, type Env } from "./relay";

const deps: Deps = {
  fetch: (input, init) => fetch(input, init),
  now: () => Math.floor(Date.now() / 1000),
  log: (line) => console.log(JSON.stringify(line)),
};

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env, deps);
  },
};
