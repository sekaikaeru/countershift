#!/usr/bin/env node
// Checks a production Web build (tools/build_web.sh http://127.0.0.1:8801) against a local API on
// 127.0.0.1:8801 standing in for Workers: the test-only page options are off, the configured API
// is used whatever the URL says, and the production verifier setup (its own local copy of the
// build, the API on another origin) verifies runs recorded in that build.
// Usage: node tools/prodcheck.mjs [--build name]
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "../server/dev.mjs";
import { startVerifier } from "../server/verifier.mjs";
import { inspectHeader, readReplayHeader } from "../server/src/api.js";

const HERE = dirname(fileURLToPath(import.meta.url));
// --build <name>: the folder under build/ to check (default web-prod); a trial name keeps the published build untouched
const bi = process.argv.indexOf("--build");
const PROD = join(HERE, "..", "build", bi >= 0 ? process.argv[bi + 1] : "web-prod");
let total = 0, failed = 0;
const expect = (what, ok) => { total++; if (!ok) failed++; console.log(`  ${ok ? "ok  " : "FAIL"}  ${what}`); };
const env = { RATE_SALT: "pc-rate-salt-0123456789abcdef-0123456789a", VERIFIER_TOKEN: "pc-verifier-token-0000001-0123456789abcdef", ADMIN_TOKEN: "pc-admin-token-000000001-0123456789abcdef" };
const lines = [];
const s = await startServer({ port: 8801, memory: true, env, quiet: true, webDir: PROD, onReport: (l) => lines.push(l) });
const page = (q, until, seconds = 200) => new Promise((r) => {
  const out = [];
  const p = spawn(process.execPath, [join(HERE, "web_run.mjs"), `${s.url}/?${q}`, "--until", until, "--timeout", String(seconds)], { stdio: ["ignore", "pipe", "ignore"] });
  p.stdout.on("data", (d) => out.push(...String(d).split("\n")));
  p.on("exit", () => r(out));
});
const players = async () => (await s.DB.prepare("SELECT COUNT(*) AS n FROM players").first()).n;

console.log("1. test-only options are ignored by a production build");
const before = await players();
const a = await page("auto=game&ranked=1&lazy=1&name=BOT&api=http://127.0.0.1:9", "^ONLINE (unranked|need_name|sending|verifying)", 200);
const last = a.filter((l) => l.startsWith("ONLINE")).pop() || "";
expect(`?ranked=1 does not make a bot run a ranked run (${last.split(" ")[1]})`, last.startsWith("ONLINE unranked"));
expect("?api= cannot point the game elsewhere: it registered with the configured API", (await players()) === before + 1);
expect("no ticket was used for the bot run", (await s.DB.prepare("SELECT COUNT(*) AS n FROM runs WHERE started_at IS NOT NULL").first()).n === 0);

console.log("2. production verifier: its own copy of the build, the API on another origin");
await page("mkreplay=3&mkseed=9300&report=1", "^GOLDEN DONE", 300);
const reps = lines.filter((l) => l.startsWith("REPLAY ")).map((l) => l.split(" "));
expect(`recorded ${reps.length} replays in the production build`, reps.length === 3);
const ids = [];
for (const [, seed, score, wave, , b64] of reps) {
  const h = inspectHeader(await readReplayHeader(b64));
  const pid = "pc-" + seed, now = Date.now();
  await s.DB.prepare("INSERT INTO players (id, token_hash, name, created_at) VALUES (?1, 'x', ?2, ?3)").bind(pid, "PC" + seed, now).run();
  await s.DB.prepare("INSERT INTO runs (id, player_id, seed, issued_at, started_at, used) VALUES (?1, ?2, ?3, ?4, ?4, 1)").bind("run-" + pid, pid, Number(seed), now).run();
  await s.DB.prepare("INSERT INTO submissions (id, player_id, run_id, score, wave, duration_ms, frames, platform, build, fp, status, replay, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'pending', ?11, ?12)")
    .bind("sub-" + pid, pid, "run-" + pid, Number(score), Number(wave), h.durationMs, h.frames, h.platform, h.build, h.fp, b64, now).run();
  ids.push("sub-" + pid);
}
const v = await startVerifier({ buildDir: PROD, api: s.url, token: env.VERIFIER_TOKEN, poll: 1, once: true, log: (m) => console.log("    " + m) });
await Promise.race([v.whenIdle, new Promise((r) => setTimeout(r, 120_000))]);
await v.stop();
const st = (await s.DB.prepare("SELECT status FROM submissions WHERE id IN (?1, ?2, ?3)").bind(...ids).all()).results.map((r) => r.status);
expect(`all verified across origins: ${st.join(", ")}`, st.length === 3 && st.every((x) => x === "verified"));
await s.close();
console.log(`prodcheck: ${total} checks, ${failed} failed`);
process.exit(failed ? 1 : 0);
