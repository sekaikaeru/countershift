#!/usr/bin/env node
// Local diagnostic setup for the name entry: the diagnostic build (build/web-diag) plus a
// throw-away ranking API in memory plus a local verifier, all on 127.0.0.1 (--port, default 8782;
// --build <folder under build/>, --log <file under server/data/>). Nothing here
// talks to the production API. Diagnostic lines the page reports are appended to
// server/data/diag.log (kinds of keys and lengths only; no characters, names, ids or tokens).
import { appendFileSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "../server/dev.mjs";
import { startVerifier } from "../server/verifier.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const arg = (k, d) => { const i = process.argv.indexOf("--" + k); return i >= 0 ? process.argv[i + 1] : d; };
const WEB = join(ROOT, "build", arg("build", "web-diag"));
const PORT = Number(arg("port", "8782"));
const LOG = join(ROOT, "server", "data", arg("log", "diag.log"));
if (!existsSync(join(WEB, "index.html"))) { console.error(WEB + " is missing"); process.exit(1); }
const mk = () => randomBytes(32).toString("hex");
const env = { RATE_SALT: mk(), VERIFIER_TOKEN: mk(), ADMIN_TOKEN: mk() };
const stamp = () => new Date().toTimeString().slice(0, 8);
const s = await startServer({ port: PORT, memory: true, env, quiet: true, webDir: WEB,
  onReport: (text) => { for (const line of text.split("\n")) if (line.startsWith("DIAG ")) appendFileSync(LOG, `${stamp()} ${line.slice(5, 220)}\n`); } });
appendFileSync(LOG, `${stamp()} --- diagnostic server started ---\n`);
console.log(`diagnostic build: ${s.url}/?diag=1  (log: ${LOG})`);
try {
  await startVerifier({ game: s.url + "/", token: env.VERIFIER_TOKEN, poll: 1, log: () => {} });
} catch (e) {
  console.log("local verifier not started: " + e.message);
}
