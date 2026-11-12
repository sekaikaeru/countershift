#!/usr/bin/env node
// Ranking administration from the command line.
//   ADMIN_TOKEN=... node server/admin.mjs --api <url> list [pending|verified|rejected]
//   ... queue    (what waits for which verifier)
//   ... hide <player_id> | unhide <player_id> | ban <player_id> | unban <player_id>
//   ... delete <player_id> | rename <player_id> <name> | requeue <submission_id> | cleanup
const args = process.argv.slice(2);
const i = args.indexOf("--api");
const api = i >= 0 ? args.splice(i, 2)[1] : "http://127.0.0.1:8787";
let token = process.env.ADMIN_TOKEN || "";
const prod = args.indexOf("--prod");
if (prod >= 0) { args.splice(prod, 1); if (!token) token = (await import("../tools/make_secrets.mjs")).readSecret("ADMIN_TOKEN"); }   // from server/.prod.secrets.json
const [cmd, a, b] = args;
if (!cmd || token.length < 32) { console.error("usage: ADMIN_TOKEN=... node server/admin.mjs [--api url] <command> ..."); process.exit(2); }
const call = async (path, body) => {
  const r = await fetch(api + path, { method: body ? "POST" : "GET", headers: { authorization: "Bearer " + token, "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  return r.json();
};
const map = {
  list: () => call("/v1/admin/list" + (a ? "?status=" + a : "")),
  queue: () => call("/v1/admin/queue"),
  hide: () => call("/v1/admin/hide", { player_id: a, hidden: true }),
  unhide: () => call("/v1/admin/hide", { player_id: a, hidden: false }),
  ban: () => call("/v1/admin/ban", { player_id: a, banned: true }),
  unban: () => call("/v1/admin/ban", { player_id: a, banned: false }),
  delete: () => call("/v1/admin/delete", { player_id: a }),
  rename: () => call("/v1/admin/rename", { player_id: a, name: b }),
  requeue: () => call("/v1/admin/requeue", { id: a }),
  cleanup: () => call("/v1/admin/cleanup", {}),
};
if (!map[cmd]) { console.error("unknown command"); process.exit(2); }
console.log(JSON.stringify(await map[cmd](), null, 2));
