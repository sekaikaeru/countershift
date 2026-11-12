#!/usr/bin/env node
// Cross-browser replay check: does Safari's engine (WebKit) compute COUNTERSHIFT exactly like
// Chrome? Both directions are tested with the real Web build and the real verifier code:
//   1. both engines print the build fingerprint and the behaviour fingerprint of 8 bot games;
//   2. runs recorded in WebKit are verified by the Chrome verifier;
//   3. runs recorded in Chrome are verified by a verifier running in WebKit;
//   4. the ranking screen is rendered by WebKit (snapshot).
// WebKit runs through tools/webkit_run.swift (WKWebView, invisible, never takes focus).
// Usage: node tools/xbrowser.mjs --webkit <webkit_run binary> [--shots <dir>]
import { spawn } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "../server/dev.mjs";
import { startVerifier } from "../server/verifier.mjs";
import { inspectHeader, readReplayHeader, BUILD } from "../server/src/api.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (k) => { const i = process.argv.indexOf("--" + k); return i >= 0 ? process.argv[i + 1] : ""; };
const WEBKIT = arg("webkit");
const shots = arg("shots");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let total = 0, failed = 0;
const expect = (what, ok) => { total++; if (!ok) failed++; console.log(`  ${ok ? "ok  " : "FAIL"}  ${what}`); };

const env = { RATE_SALT: "xb-rate-salt-0123456789abcdef-0123456789a", VERIFIER_TOKEN: "xb-verifier-token-0000001-0123456789abcdef", ADMIN_TOKEN: "xb-admin-token-000000001-0123456789abcdef" };
const reports = { chrome: [], webkit: [] };
const s = await startServer({ port: 8796, memory: true, env, quiet: true,
  onReport: (line, ua) => {
    const who = /Chrome\//.test(ua) ? "chrome" : "webkit";
    reports[who].push(line);
    if (!line.startsWith("REPLAY")) console.log(`    [${who}] ${line.slice(0, 110)}`);
  } });

const waitFor = async (who, re, ms) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (reports[who].some((l) => re.test(l))) return true; await sleep(250); } return false; };
const chrome = (url, seconds) => new Promise((r) => {
  const p = spawn(process.execPath, [join(HERE, "web_run.mjs"), url, "--until", "^(GOLDEN DONE|VERIFIER IDLE)", "--timeout", String(seconds)], { stdio: "ignore" });
  p.on("exit", r);
});
const webkit = (url, seconds, shot = "", at = 0) => new Promise((r) => {
  const p = spawn(WEBKIT, [url, String(seconds), ...(shot ? [shot, String(at)] : [])], { stdio: ["ignore", "pipe", "inherit"] });
  p.stdout.on("data", (d) => { const t = String(d).trim(); if (t.includes("snapshot")) console.log("    " + t); });
  p.on("exit", r);
  return p;
});
const runKilled = (url, seconds, until) => {
  const p = spawn(WEBKIT, [url, String(seconds)], { stdio: "ignore" });
  return waitFor("webkit", until, seconds * 1000).then(async (ok) => { p.kill(); await sleep(300); return ok; });
};

console.log(`1. fingerprints (build ${BUILD})`);
const q = "golden=8&mkreplay=4&report=1";
await Promise.all([
  chrome(`${s.url}/?${q}&mkseed=7000`, 300),
  runKilled(`${s.url}/?${q}&mkseed=8000`, 300, /^GOLDEN DONE/),
]);
const fp = (who) => reports[who].find((l) => l.startsWith("FP "));
const golden = (who) => reports[who].filter((l) => l.startsWith("skill "));
console.log(`    chrome ${fp("chrome")} | webkit ${fp("webkit")}`);
expect("WebKit ran the game and reported", !!fp("webkit") && golden("webkit").length === 8);
expect("same build fingerprint in Chrome and WebKit", fp("chrome") && fp("chrome") === fp("webkit"));
const gd = golden("chrome").filter((l, i) => l !== golden("webkit")[i]);
expect(`the 8 behaviour fingerprints are identical (${golden("chrome").length} vs ${golden("webkit").length}, ${gd.length} differ)`, golden("chrome").length === 8 && gd.length === 0);

// queue the replays recorded by one engine for the verifier of the other
const queue = async (who) => {
  const ids = [];
  for (const line of reports[who].filter((l) => l.startsWith("REPLAY "))) {
    const [, seed, score, wave, timeMs, b64] = line.split(" ");
    const h = inspectHeader(await readReplayHeader(b64));
    const pid = `${who}-${seed}`;
    const now = Date.now();
    await s.DB.prepare("INSERT INTO players (id, token_hash, name, created_at) VALUES (?1, 'x', ?2, ?3)").bind(pid, `${who.toUpperCase()}${seed}`, now).run();
    await s.DB.prepare("INSERT INTO runs (id, player_id, seed, issued_at, started_at, used) VALUES (?1, ?2, ?3, ?4, ?4, 1)").bind("run-" + pid, pid, Number(seed), now).run();
    await s.DB.prepare("INSERT INTO submissions (id, player_id, run_id, score, wave, duration_ms, frames, platform, build, fp, status, replay, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'pending', ?11, ?12)")
      .bind("sub-" + pid, pid, "run-" + pid, Number(score), Number(wave), h.durationMs, h.frames, h.platform, h.build, h.fp, b64, now).run();
    expect(`${who} replay seed ${seed}: header play time ${h.durationMs} ms = reported ${timeMs} ms`, h.durationMs === Number(timeMs));
    ids.push("sub-" + pid);
  }
  return ids;
};
const statuses = async (ids) => (await s.DB.prepare(`SELECT id, status, reason, score FROM submissions WHERE id IN (${ids.map((_, i) => "?" + (i + 1)).join(",")})`).bind(...ids).all()).results;

console.log("2. runs recorded in WebKit, verified by the Chrome verifier");
const fromWebkit = await queue("webkit");
const v = await startVerifier({ game: s.url + "/", token: env.VERIFIER_TOKEN, poll: 1, once: true, log: (m) => console.log("    " + m) });
await Promise.race([v.whenIdle, sleep(120_000)]);
await v.stop();
for (const r of await statuses(fromWebkit)) expect(`${r.id} (score ${r.score}): ${r.status} ${r.reason}`, r.status === "verified");

console.log("3. runs recorded in Chrome, verified by a verifier running in WebKit");
const fromChrome = await queue("chrome");
await runKilled(`${s.url}/?verify=1&once=1&report=1&vpoll=1&vtoken=${env.VERIFIER_TOKEN}`, 180, /^VERIFIER IDLE/);
for (const r of await statuses(fromChrome)) expect(`${r.id} (score ${r.score}): ${r.status} ${r.reason}`, r.status === "verified");

if (shots) {
  console.log("4. ranking and title rendered by WebKit");
  await webkit(`${s.url}/?auto=ranking&lang=ja`, 14, join(shots, "webkit_ranking_ja.png"), 11);
  await webkit(`${s.url}/?lang=en`, 12, join(shots, "webkit_title_en.png"), 9);
}

await s.close();
console.log(`xbrowser: ${total} checks, ${failed} failed`);
process.exit(failed ? 1 : 0);
