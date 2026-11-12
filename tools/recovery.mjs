#!/usr/bin/env node
// Queue recovery check with the real pieces (Web build, worker code on a SQLite file, verifier):
//   - runs submitted while no verifier runs stay queued, also across a server restart;
//   - a job leased by a verifier that then died is handed out again once the lease runs out;
//   - the verifier survives the API being unreachable for a while, and a Chrome crash.
// Usage: node tools/recovery.mjs
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "../server/dev.mjs";
import { startVerifier } from "../server/verifier.mjs";
import { inspectHeader, readReplayHeader, LIMITS } from "../server/src/api.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let total = 0, failed = 0;
const expect = (what, ok) => { total++; if (!ok) failed++; console.log(`  ${ok ? "ok  " : "FAIL"}  ${what}`); };
const realNow = Date.now;
let skew = 0;
Date.now = () => realNow() + skew;

const env = { RATE_SALT: "rc-rate-salt-0123456789abcdef-0123456789a", VERIFIER_TOKEN: "rc-verifier-token-0000001-0123456789abcdef", ADMIN_TOKEN: "rc-admin-token-000000001-0123456789abcdef" };
const dir = mkdtempSync(join(tmpdir(), "cs-recovery-"));
const dbFile = join(dir, "ranking.sqlite");
const PORT = 8798;
const lines = [];
let s = await startServer({ port: PORT, dbFile, env, quiet: true, onReport: (l) => lines.push(l) });

console.log("0. record 5 real replays in the Web build (Chrome)");
await new Promise((r) => spawn(process.execPath, [join(HERE, "web_run.mjs"), `${s.url}/?mkreplay=5&mkseed=9100&report=1`, "--until", "^GOLDEN DONE", "--timeout", "300"], { stdio: "ignore" }).on("exit", r));
const replays = lines.filter((l) => l.startsWith("REPLAY ")).map((l) => l.split(" "));
expect(`recorded ${replays.length} replays`, replays.length === 5);
let n = 0;
const queueOne = async () => {
  const [, seed, score, wave, , b64] = replays[n++];
  const h = inspectHeader(await readReplayHeader(b64));
  const pid = "rc-" + seed, now = Date.now();
  await s.DB.prepare("INSERT INTO players (id, token_hash, name, created_at) VALUES (?1, 'x', ?2, ?3)").bind(pid, "RC" + seed, now).run();
  await s.DB.prepare("INSERT INTO runs (id, player_id, seed, issued_at, started_at, used) VALUES (?1, ?2, ?3, ?4, ?4, 1)").bind("run-" + pid, pid, Number(seed), now).run();
  await s.DB.prepare("INSERT INTO submissions (id, player_id, run_id, score, wave, duration_ms, frames, platform, build, fp, status, replay, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'pending', ?11, ?12)")
    .bind("sub-" + pid, pid, "run-" + pid, Number(score), Number(wave), h.durationMs, h.frames, h.platform, h.build, h.fp, b64, now + n).run();
  return { id: "sub-" + pid, fp: h.fp };
};
const status = async (id) => (await s.DB.prepare("SELECT status, reason, attempts FROM submissions WHERE id = ?1").bind(id).first());
const waitStatus = async (id, want, ms) => { const t0 = realNow(); while (realNow() - t0 < ms) { if ((await status(id))?.status === want) return true; await sleep(300); } return false; };

console.log("1. no verifier running: runs wait, also through a server restart");
const a = await queueOne(), b = await queueOne();
await sleep(1500);
expect("queued runs stay pending while no verifier runs", (await status(a.id)).status === "pending" && (await status(b.id)).status === "pending");
await s.close();
s = await startServer({ port: PORT, dbFile, env, quiet: true });
expect("after the server restarts, the queue is still there", (await status(a.id)).status === "pending" && (await status(b.id)).status === "pending");

console.log("2. a verifier takes a job and dies before answering (Mac goes to sleep mid-job)");
const lease = await (await fetch(`${s.url}/v1/verify/next?platform=1&fp=${a.fp}`, { headers: { authorization: "Bearer " + env.VERIFIER_TOKEN } })).json();
expect(`the first job (${lease.id}) is leased and nobody answers`, lease.id === a.id);

console.log("3. the verifier starts (Mac wakes up): it works through the backlog");
const log = [];
const v = await startVerifier({ game: s.url + "/", token: env.VERIFIER_TOKEN, poll: 1, log: (m) => { log.push(m); console.log("    " + m); } });
await v.whenReady;
expect("the job nobody can take yet (its lease runs) is not verified twice", await waitStatus(b.id, "verified", 60_000) && (await status(a.id)).status === "pending");
skew += LIMITS.leaseMs + 1000;
expect("once the lease ran out, the abandoned job is verified too", await waitStatus(a.id, "verified", 60_000));
expect(`it counted 2 attempts (${(await status(a.id)).attempts})`, (await status(a.id)).attempts === 2);

console.log("4. the API is unreachable for a while, then comes back");
await s.close();
await sleep(8000);
s = await startServer({ port: PORT, dbFile, env, quiet: true });
const c = await queueOne();
expect("the verifier carries on by itself after the outage", await waitStatus(c.id, "verified", 60_000));

console.log("5. Chrome crashes: the verifier restarts it");
const pid = v.chromePid();
process.kill(pid, "SIGKILL");
const d = await queueOne();
expect("a new Chrome was started", await (async () => { const t0 = realNow(); while (realNow() - t0 < 30_000) { if (v.starts() >= 2) return true; await sleep(300); } return false; })());
expect("and the next run is verified", await waitStatus(d.id, "verified", 90_000));

const board = (await (await fetch(`${s.url}/v1/top`)).json());
expect(`board: ${board.total} players, counter matches rows`, board.total === 4 && board.entries.length === 4);
await v.stop();
await s.close();
rmSync(dir, { recursive: true, force: true });
console.log(`recovery: ${total} checks, ${failed} failed`);
process.exit(failed ? 1 : 0);
