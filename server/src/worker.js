// COUNTERSHIFT ranking API (Cloudflare Workers + D1): entry point.
// workerd accepts only handlers as exports of the entry module, so the logic lives in api.js.
import { handle } from "./api.js";

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch (e) {
      console.error("unhandled", e?.stack || String(e));
      return new Response(JSON.stringify({ ok: false, error: "server_error" }), {
        status: 500,
        headers: { "content-type": "application/json; charset=utf-8", "access-control-allow-origin": "*", "cache-control": "no-store" },
      });
    }
  },
};
