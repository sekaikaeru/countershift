// A stand-in for the Cloudflare API, for cf-guard.test.mjs. Runs as its own process; the test
// writes what the "account" looks like into the JSON file given as the first argument.
import http from "node:http";
import { readFileSync } from "node:fs";
const file = process.argv[2];
const server = http.createServer((req, res) => {
  const world = JSON.parse(readFileSync(file, "utf8"));
  const send = (result, ok = true) => { res.writeHead(ok ? 200 : 403, { "content-type": "application/json" }); res.end(JSON.stringify({ success: ok, result })); };
  if (req.headers.authorization !== "Bearer " + world.token) return send(null, false);
  const p = req.url.split("?")[0].replace("/client/v4", "");
  if (p === "/user/tokens/verify") return send({ status: world.tokenStatus });
  if (p === "/accounts") return send(world.accounts);
  if (p.endsWith("/workers/scripts")) return send(world.workers.map((id) => ({ id })));
  if (p.endsWith("/countershift-ranking/settings")) return send({ bindings: [{ type: "d1", name: "DB", id: "db-uuid-0001" }, { type: "secret_text", name: "RATE_SALT" }, { type: "ratelimit", name: "RL_READ", simple: { limit: 60, period: 60 } }] });
  if (p.endsWith("/countershift-ranking/subdomain")) return send({ enabled: world.public === true, previews_enabled: false });
  if (p.endsWith("/workers/subdomain")) return send({ subdomain: "cs-test" });
  if (p.endsWith("/d1/database")) return send(world.dbs.map((name) => ({ name, uuid: "db-uuid-0001" })));
  send(null, false);
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));
