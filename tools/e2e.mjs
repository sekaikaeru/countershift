#!/usr/bin/env node
// End-to-end check with the real pieces: the Web build in headless Chrome, the worker code
// on a local database, and the Web verifier. Nothing leaves this machine.
// Usage: node tools/e2e.mjs [--shots <dir>]      (export the Web build first)
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "../server/dev.mjs";
import { startVerifier } from "../server/verifier.mjs";
import { BUILD } from "../server/src/api.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const shotsAt = process.argv.indexOf("--shots");
const shots = shotsAt >= 0 ? process.argv[shotsAt + 1] : null;
const env = { RATE_SALT: "e2e-rate-salt-0123456789abcdef-0123456789", VERIFIER_TOKEN: "e2e-verifier-token-000001-0123456789abcdef", ADMIN_TOKEN: "e2e-admin-token-00000001-0123456789abcdef" };
const realNow = Date.now;
let skew = 0;
Date.now = () => realNow() + skew;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let total = 0, failed = 0;
const expect = (what, ok) => { total++; if (!ok) failed++; console.log(`  ${ok ? "ok  " : "FAIL"}  ${what}`); };

/** Runs the game page; resolves with its console lines once `until` matches (or on timeout). */
function game(url, { until, timeout = 420, shot = null, profile = null, after = 0, onLine = null }) {
  return new Promise((resolve) => {
    const args = [join(HERE, "web_run.mjs"), url, "--until", until, "--timeout", String(timeout)];
    if (shot && shots) args.push("--shot", join(shots, shot));
    if (profile) args.push("--profile-dir", profile);
    if (after) args.push("--after", String(after));
    const p = spawn(process.execPath, args, { stdio: ["ignore", "pipe", "inherit"] });
    const lines = [];
    let buf = "";
    p.stdout.on("data", (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1); lines.push(line); if (onLine) onLine(line); }
    });
    p.on("exit", (code) => resolve({ ok: code === 0, lines }));
  });
}
const last = (lines, prefix) => lines.filter((l) => l.startsWith(prefix)).pop() || "";
const api = async (s, method, path, body, bearer) => (await fetch(s.url + path, { method, headers: { "content-type": "application/json", ...(bearer ? { authorization: "Bearer " + bearer } : {}) }, body: body ? JSON.stringify(body) : undefined })).json();

const s = await startServer({ port: 8791, memory: true, env, quiet: true });
const v = await startVerifier({ game: s.url + "/", token: env.VERIFIER_TOKEN, poll: 1, log: (m) => console.log("  " + m) });
await v.whenReady;
const profile = mkdtempSync(join(tmpdir(), "cs-e2e-profile-"));
const base = `${s.url}/?auto=game&ranked=1&autokeys=1&skill=0.35&profile=e2e`;

const only5 = process.argv.includes("--only5");
if (!only5) {
console.log("1. first start with no saved data: play a ranked run; the server goes away while the record is sent");
let downAt = 0;
const r1 = await game(base + "&name=E2E%20BOT&resend=4&lang=en", {
  until: "^ONLINE (verified|rejected|unranked|queued)", profile, shot: "result_verified_en.png", after: 2.5,
  onLine: (line) => {
    if (line.startsWith("fps") && !downAt && / t (\d+)/.test(line) && Number(line.match(/ t (\d+)/)[1]) >= 8) { downAt = 1; s.state.down = true; }
    if (line.startsWith("ONLINE error")) s.state.down = false;       // the server comes back; the game sends again
  },
});
console.log("  " + r1.lines.filter((l) => l.startsWith("ONLINE")).join("\n  "));
expect("the run was played while the server was unreachable", downAt === 1);
expect("the failed send was reported to the player", r1.lines.some((l) => l.startsWith("ONLINE error")));
expect("after sending again the record was verified by replay", last(r1.lines, "ONLINE").startsWith("ONLINE verified"));
let top = await api(s, "GET", "/v1/top");
const score1 = top.entries[0]?.score ?? 0;
expect(`the board shows it: ${JSON.stringify(top.entries.map((e) => [e.rank, e.name, e.score, e.wave]))}`, top.entries.length === 1 && top.entries[0].name === "E2E BOT" && score1 > 0);

console.log("2. cheating with a real replay (checked by the real verifier)");
const stored = await s.DB.prepare("SELECT s.replay, s.score, s.wave, s.duration_ms, r.seed FROM submissions s JOIN runs r ON r.id = s.run_id WHERE s.status = 'verified'").first();
const cheat = async (label, mutate, wantStatus) => {
  const p = await api(s, "POST", "/v1/player");
  const auth = { player_id: p.player_id, token: p.token };
  const run = await api(s, "POST", "/v1/run", auth);
  const sameSeed = mutate.sameSeed !== false;
  if (sameSeed) await s.DB.prepare("UPDATE runs SET seed = ?1 WHERE id = ?2").bind(stored.seed, run.run_id).run();   // give the cheater the same seed
  await api(s, "POST", "/v1/run/start", { ...auth, run_id: run.run_id });
  skew += stored.duration_ms + 1000;
  const sub = await api(s, "POST", "/v1/submit", { ...auth, run_id: run.run_id, name: "CHEAT", score: stored.score + (mutate.add || 0), wave: stored.wave, replay: mutate.replay || stored.replay });
  if (sub.status !== "pending") return expect(`${label}: ${sub.error || sub.status}`, (sub.error || sub.status) === wantStatus);
  let st = { status: "pending" };
  for (let i = 0; i < 80 && st.status === "pending"; i++) { await sleep(500); st = await api(s, "POST", "/v1/submission", { ...auth, submission_id: sub.submission_id }); }
  expect(`${label}: ${st.status} ${st.reason || ""}`, st.status === wantStatus);
};
await cheat("someone else's replay on another ticket", { sameSeed: false }, "seed_mismatch");
await cheat("true replay, score raised by 10", { add: 10 }, "rejected");
const { gunzipSync, gzipSync } = await import("node:zlib");
const raw = gunzipSync(Buffer.from(stored.replay, "base64"));
for (let f = 200; f < 260; f++) raw[28 + f * 9 + 8] ^= 16;          // hold shift for a second where the player did not
await cheat("edited inputs, original score claimed", { replay: gzipSync(raw).toString("base64") }, "rejected");
await cheat("the honest replay itself", {}, "verified");
top = await api(s, "GET", "/v1/top");
expect("the board holds only verified runs: " + JSON.stringify(top.entries.map((e) => [e.name, e.score])), top.entries.length === 2 && top.entries.every((e) => e.score === score1) && top.entries[0].name === "E2E BOT");

console.log("3. reload the browser: the same player, the saved name, the best-only rule");
const r3 = await game(base + "&lang=ja", { until: "^ONLINE (verified|rejected|unranked|queued|not_best|error)", profile, shot: "result_second_ja.png", after: 2.5 });
const st3 = last(r3.lines, "ONLINE").split(" ")[1];
const players = (await s.DB.prepare("SELECT COUNT(*) AS n FROM players WHERE name = 'E2E BOT'").first()).n;
expect(`second run after reload ended as "${st3}" without asking for a name`, ["verified", "not_best"].includes(st3) && !r3.lines.some((l) => l.startsWith("ONLINE need_name")));
expect("it is still one player on the server", players === 1);
top = await api(s, "GET", "/v1/top");
expect("and one row on the board for that player", top.entries.filter((e) => e.name === "E2E BOT").length === 1);

console.log("4. ranking screen with a full board (top 100 of 141)");
for (let i = 0; i < 139; i++) {
  await s.DB.prepare("INSERT INTO scores (player_id, name, score, wave, achieved_at, submission_id) VALUES (?1, ?2, ?3, ?4, ?5, 'seed')")
    .bind("fake" + i, ["シフトの達人", "NEON", "かわりみ", "Pilot_07", "山田", "COUNTER"][i % 6] + (i + 1), 180000 - i * 1234 + (i % 7) * 100, 22 - Math.floor(i / 8), realNow() - i * 3600_000).run();
}
skew += 21_000;      // rows were written behind the API's back: let its 20 s top-100 cache run out
const r4 = await game(`${s.url}/?auto=ranking&profile=e2e&lang=ja`, { until: "^BOARD (ok|error)", profile, shot: "ranking_ja.png", after: 1.5 });
const b4 = last(r4.lines, "BOARD");
expect("the ranking screen loaded 100 entries and knows our own rank outside them: " + b4.slice(0, 120), /^BOARD ok entries=100 total=141 me=\{.*"rank":1\d\d/.test(b4));
await game(`${s.url}/?auto=ranking&profile=e2e&lang=en`, { until: "^BOARD (ok|error)", profile, shot: "ranking_en.png", after: 1.5 });

}
console.log("5. server trouble never blocks the game");
s.state.delayMs = 20_000;
const r5 = await game(`${s.url}/?auto=ranking&profile=slow`, { until: "^BOARD (ok|error)", timeout: 40, shot: "ranking_error.png", after: 1 });
expect("a server that does not answer: the ranking screen gives up after the timeout and says so", last(r5.lines, "BOARD").startsWith("BOARD error"));
const t5 = realNow();
const r5b = await game(`${s.url}/?auto=game&ranked=1&lazy=1&profile=slow2`, { until: "^ONLINE unranked", timeout: 150, shot: "result_offline.png", after: 4 });
expect(`with a silent server the run still starts and ends normally, marked as not ranked (${Math.round((realNow() - t5) / 1000)} s)`, last(r5b.lines, "ONLINE").startsWith("ONLINE unranked"));
s.state.delayMs = 0;
const r5c = await game(`${s.url}/?auto=game&ranked=1&lazy=1&profile=none&api=http://127.0.0.1:9`, { until: "^ONLINE unranked", timeout: 150 });
expect("with no server at all the game plays the same and the run is not ranked", last(r5c.lines, "ONLINE").startsWith("ONLINE unranked"));

await v.stop();
await s.close();
rmSync(profile, { recursive: true, force: true });
console.log(`e2e: ${total} checks, ${failed} failed (worker build ${BUILD})`);
process.exit(failed ? 1 : 0);
