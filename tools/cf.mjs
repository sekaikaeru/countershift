#!/usr/bin/env node
// The only door to Cloudflare for COUNTERSHIFT. It runs wrangler against the game's OWN
// Cloudflare account and refuses to run anywhere else.
//
// How the separation works:
//   - credentials come from server/.cf.env (git-ignored, mode 600): an API token that can see
//     only the COUNTERSHIFT account, and that account's id. wrangler uses an API token from the
//     environment before any stored login, so the OAuth login used for other projects is never used;
//   - wrangler's own settings directory is redirected (XDG_CONFIG_HOME) to server/.cf-home, so the
//     stored login of other projects is not even read, and nothing is written next to it;
//   - before every command the guard asks Cloudflare what the token can see, and stops unless it is
//     exactly one account, the pinned one, holding nothing but resources named countershift-*.
//
//   node tools/cf.mjs check                 who am I, what would be touched (read only)
//   node tools/cf.mjs pin                   remember this account as the COUNTERSHIFT account
//   node tools/cf.mjs inventory             Workers and D1 databases in the account (read only)
//   node tools/cf.mjs status                the Worker's bindings (names only) and whether it is public (read only)
//   node tools/cf.mjs url                   the API's public address (read only)
//   node tools/cf.mjs wrangler <args...>    run wrangler there; changing commands need CF_CONFIRM=<last 4 of account id>
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SERVER = join(ROOT, "server");
const ENV_FILE = process.env.CF_ENV_FILE || join(SERVER, ".cf.env");
const PIN_FILE = process.env.CF_PIN_FILE || join(SERVER, ".cf.pin");
const HOME_DIR = process.env.CF_HOME_DIR || join(SERVER, ".cf-home");
const API = process.env.CF_API_BASE || "https://api.cloudflare.com/client/v4";      // (overridden only by the tests)
const WRANGLER = process.env.CF_WRANGLER ? [process.env.CF_WRANGLER] : ["npx", "--yes", "wrangler@4.160.0"];
const OURS = /^countershift-/;                               // every Worker and D1 database of the game is named like this
// read-only wrangler commands; anything else counts as changing the account and needs CF_CONFIRM
const READ_ONLY = ["whoami", "d1 list", "d1 info", "d1 export", "d1 time-travel info", "d1 insights", "deployments list", "deployments status", "versions list", "versions view", "secret list", "tail", "docs"];

const die = (msg) => { console.error("STOP: " + msg); process.exit(1); };
const mask = (id) => "…" + String(id).slice(-4);
const sha = (s) => createHash("sha256").update(s).digest("hex");

function loadEnv() {
  if (!existsSync(ENV_FILE)) die(`${ENV_FILE} is missing. Create it first (docs/ONLINE-RANKING.md, chapter 8).`);
  if ((statSync(ENV_FILE).mode & 0o077) !== 0) die(`${ENV_FILE} can be read by others. Run: chmod 600 server/.cf.env`);
  const out = {};
  for (const line of readFileSync(ENV_FILE, "utf8").split("\n")) {
    const m = line.match(/^\s*(CLOUDFLARE_API_TOKEN|CLOUDFLARE_ACCOUNT_ID)\s*=\s*(\S+)\s*$/);
    if (m) out[m[1]] = m[2];
  }
  if (!out.CLOUDFLARE_API_TOKEN || out.CLOUDFLARE_API_TOKEN.length < 20) die("CLOUDFLARE_API_TOKEN is missing in server/.cf.env");
  if (!/^[0-9a-f]{32}$/.test(out.CLOUDFLARE_ACCOUNT_ID || "")) die("CLOUDFLARE_ACCOUNT_ID is missing or malformed in server/.cf.env");
  return out;
}

async function cf(env, path) {
  let r;
  try {
    r = await fetch(API + path, { headers: { authorization: "Bearer " + env.CLOUDFLARE_API_TOKEN } });
  } catch (e) {
    die("Cloudflare could not be reached (" + e.message + ")");
  }
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok && body.success === true, status: r.status, result: body.result ?? null };
}

/** Asks Cloudflare what this token is and can see. Stops on anything unexpected. */
async function guard(env, { needPin = true } = {}) {
  const id = env.CLOUDFLARE_ACCOUNT_ID;
  let v = await cf(env, "/user/tokens/verify");
  if (!v.ok) v = await cf(env, `/accounts/${id}/tokens/verify`);
  if (!v.ok || v.result?.status !== "active") die("the API token is not valid or not active");
  const acc = await cf(env, "/accounts?per_page=50");
  if (!acc.ok) die("the token cannot list its accounts (give it Account Settings: Read)");
  const ids = acc.result.map((a) => a.id);
  if (ids.length !== 1) die(`the token can see ${ids.length} accounts; it must see exactly one (restrict it to the COUNTERSHIFT account)`);
  if (ids[0] !== id) die("the account the token can see is not the CLOUDFLARE_ACCOUNT_ID of server/.cf.env");
  const scripts = await cf(env, `/accounts/${id}/workers/scripts`);
  const d1 = await cf(env, `/accounts/${id}/d1/database?per_page=100`);
  if (!scripts.ok || !d1.ok) die("the token cannot list Workers or D1 (it needs Workers Scripts: Edit and D1: Edit)");
  const workers = scripts.result.map((s) => s.id);
  const dbs = d1.result.map((d) => d.name);
  // anything not named countershift-* means this is some other project's account: stop before touching it
  const foreign = [...workers, ...dbs].filter((n) => !OURS.test(n));
  if (foreign.length) die(`this account holds resources of another project (${foreign.join(", ")}). This is NOT the COUNTERSHIFT account.`);
  const pinned = existsSync(PIN_FILE) ? readFileSync(PIN_FILE, "utf8").trim() : "";
  if (needPin && !pinned) die("this account is not pinned yet. Look at `node tools/cf.mjs check`, then run `node tools/cf.mjs pin`.");
  if (pinned && pinned !== sha(id)) die("server/.cf.env points at a different account than the pinned COUNTERSHIFT account");
  return { name: acc.result[0].name, id, workers, dbs, pinned: !!pinned, others: [...workers, ...dbs].filter((n) => !OURS.test(n)) };
}

function show(g) {
  console.log(`account: "${g.name}" (id ${mask(g.id)})${g.pinned ? " — pinned as the COUNTERSHIFT account" : " — NOT pinned yet"}`);
  console.log(`Workers (${g.workers.length}): ${g.workers.join(", ") || "none"}`);
  console.log(`D1 databases (${g.dbs.length}): ${g.dbs.join(", ") || "none"}`);
  if (g.others.length) console.log(`note: not named countershift-*: ${g.others.join(", ")}`);
}

function runWrangler(env, args) {
  mkdirSync(HOME_DIR, { recursive: true, mode: 0o700 });
  const clean = { ...process.env };
  for (const k of Object.keys(clean)) if (/^(CLOUDFLARE_|CF_API|WRANGLER_)/.test(k)) delete clean[k];
  const r = spawnSync(WRANGLER[0], [...WRANGLER.slice(1), ...args], {
    cwd: SERVER, stdio: "inherit",
    env: { ...clean, CLOUDFLARE_API_TOKEN: env.CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID: env.CLOUDFLARE_ACCOUNT_ID,
      XDG_CONFIG_HOME: HOME_DIR, WRANGLER_SEND_METRICS: "false" },
  });
  process.exit(r.status ?? 1);
}

const [cmd, ...rest] = process.argv.slice(2);
const env = loadEnv();
if (cmd === "check" || cmd === "inventory") {
  const g = await guard(env, { needPin: false });
  show(g);
  console.log("ok: one account, the expected one, nothing of another project in it. Nothing was changed.");
} else if (cmd === "status") {
  // what Cloudflare holds for the Worker: bindings (names only) and whether it has a public address. Read only.
  const g = await guard(env);
  const name = "countershift-ranking";
  if (!g.workers.includes(name)) die(`there is no Worker called ${name} in this account`);
  const st = await cf(env, `/accounts/${g.id}/workers/scripts/${name}/settings`);
  const sd = await cf(env, `/accounts/${g.id}/workers/scripts/${name}/subdomain`);
  const d1 = await cf(env, `/accounts/${g.id}/d1/database?per_page=100`);
  if (!st.ok || !sd.ok) die("could not read the Worker's settings");
  console.log(`account: "${g.name}" (id ${mask(g.id)}) · Worker ${name}`);
  for (const b of st.result.bindings || []) {
    let extra = "";
    if (b.type === "d1") {
      const db = (d1.result || []).find((x) => x.uuid === (b.id || b.database_id));
      extra = db ? ` -> D1 "${db.name}" (id ${mask(db.uuid)})` : " -> a D1 database NOT in this account's list";
    } else if (b.type === "ratelimit") {
      extra = ` ${b.simple?.limit}/${b.simple?.period}s`;
    } else if (b.type === "secret_text") {
      extra = " (value never readable)";
    }
    console.log(`  binding ${b.name}: ${b.type}${extra}`);
  }
  console.log(`workers.dev route: ${sd.result.enabled ? "ENABLED (public)" : "disabled"}`);
  console.log(`version (preview) URLs: ${sd.result.previews_enabled ? "ENABLED (public)" : "disabled"}`);
} else if (cmd === "url") {
  // the public address the API has (or will have, once workers_dev is true). Read only.
  const g = await guard(env);
  const sub = await cf(env, `/accounts/${g.id}/workers/subdomain`);
  if (!sub.ok || !sub.result?.subdomain) die("the account has no workers.dev subdomain yet (open Workers & Pages in the dashboard once)");
  console.log(`https://countershift-ranking.${sub.result.subdomain}.workers.dev`);
} else if (cmd === "pin") {
  const g = await guard(env, { needPin: false });
  show(g);
  if (process.env.CF_CONFIRM !== String(g.id).slice(-4)) die(`to pin this account, run again with CF_CONFIRM=<last 4 characters of the account id shown above>`);
  writeFileSync(PIN_FILE, sha(g.id) + "\n", { mode: 0o600 });
  console.log("pinned. From now on every command stops if the account is not this one.");
} else if (cmd === "wrangler") {
  if (rest.includes("--profile") || rest.some((a) => a === "login" || a === "logout" || a === "auth")) die("login, logout, auth and --profile are not run through this tool");
  const g = await guard(env);
  const words = rest.filter((a) => !a.startsWith("-"));
  const readOnly = READ_ONLY.some((c) => words.slice(0, c.split(" ").length).join(" ") === c)
    || rest.includes("--dry-run") || rest.includes("--local") || rest.includes("--help") || rest.includes("--version");
  const changing = !readOnly;
  console.error(`[cf] account "${g.name}" (id ${mask(g.id)}) · wrangler ${rest.join(" ").replace(/[0-9a-f]{32}/g, "<id>")}${changing ? " · CHANGES the account" : ""}`);
  if (changing && process.env.CF_CONFIRM !== String(g.id).slice(-4)) die(`this command changes the account. Run it again with CF_CONFIRM=<last 4 characters of the account id shown above>`);
  runWrangler(env, rest);
} else {
  console.error("usage: node tools/cf.mjs check | pin | inventory | status | url | wrangler <args...>");
  process.exit(2);
}
