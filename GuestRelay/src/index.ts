// Worker entry point. The Durable Object class must be exported from here.
import { handleRequest, type Env } from "./relay";

export { HostRelay } from "./host";

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },
} satisfies ExportedHandler<Env>;
