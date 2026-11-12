#!/usr/bin/env node
// Release-candidate check on a local mock API. It serves build/web-rc1-local (the candidate's twin:
// same sources and export preset, API address = this mock) on 127.0.0.1:8784 and
//   1. reads the build's fingerprint and two behaviour fingerprints in Chrome,
//   2. plays a run through real key presses only (a production build has no test options):
//      START, Shift taps until the shields are gone, the name typed through an IME composition,
//      Enter, then waits for the local verifier and opens the ranking.
// Nothing here talks to the production API.  Usage: node tools/rc_check.mjs [--shots dir]
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "../server/dev.mjs";
import { startVerifier } from "../server/verifier.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const BUILD_DIR = join(HERE, "..", "build", "web-rc1-local");
const si = process.argv.indexOf("--shots");
const shots = si >= 0 ? process.argv[si + 1] : "";
const env = { RATE_SALT: "rc-check-rate-salt-0123456789abcdef-012345", VERIFIER_TOKEN: "rc-check-verifier-token-0123456789abcdef-01", ADMIN_TOKEN: "rc-check-admin-token-0123456789abcdef-0123" };
let total = 0, failed = 0;
const expect = (what, ok) => { total++; if (!ok) failed++; console.log(`  ${ok ? "ok  " : "FAIL"}  ${what}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const s = await startServer({ port: 8784, memory: true, env, quiet: true, webDir: BUILD_DIR });
const page = (q, extra) => new Promise((r) => {
  const out = [];
  const p = spawn(process.execPath, [join(HERE, "web_run.mjs"), `${s.url}/${q}`, ...extra], { stdio: ["ignore", "pipe", "ignore"] });
  p.stdout.on("data", (d) => out.push(...String(d).split("\n")));
  p.on("exit", () => r(out));
});

console.log("1. what this build computes (Chrome)");
const g = await page("?golden=2", ["--until", "^GOLDEN DONE", "--timeout", "240"]);
const fp = (g.find((l) => l.startsWith("FP ")) || "").slice(3);
const lines = g.filter((l) => l.startsWith("skill "));
console.log(`    build fingerprint ${fp}`);
expect("behaviour fingerprint, seed 1000 = the known Web value (hash 3245593662)", (lines[0] || "").endsWith("hash 3245593662"));
expect("behaviour fingerprint, seed 1001 = the known Web value (hash 46818714)", (lines[1] || "").endsWith("hash 46818714"));
expect("test options are off in this build (?diag=1 shows no diagnostic lines)", !(await page("?diag=1&namedebug=1", ["--until", "^boot: sound", "--timeout", "60", "--after", "3"])).some((l) => l.startsWith("DIAG") || l.startsWith("NAME")));

console.log("2. local verifier on the same build");
let ready = "";
const v = await startVerifier({ buildDir: BUILD_DIR, api: s.url, token: env.VERIFIER_TOKEN, poll: 1, log: (m) => { if (m.includes("READY")) ready = m; if (m.includes("VERIFIED")) console.log("    " + m); } });
await v.whenReady;
console.log("    " + ready);
expect("verifier and build agree on the fingerprint", ready.includes(`fp ${fp}`) && ready.includes("build 3"));

console.log("3. a run by key presses only: START, Shift taps, name through an IME composition, Enter");
const taps = [];
for (let i = 0; i < 230; i++) taps.push("Shift", "wait330");
const keys = ["Enter", "wait2500", ...taps, "wait4500",
  ...(shots ? [`shot:${shots}/rc_1_name_window.png`] : []),
  "compose:こうほ", "RealEnter", "wait300", "ime:こうほ>候補太郎", "wait300",
  ...(shots ? [`shot:${shots}/rc_2_name_typed.png`] : []),
  "RealEnter", "wait14000",
  ...(shots ? [`shot:${shots}/rc_3_result.png`] : []),
  "Tab", "wait3500",
  ...(shots ? [`shot:${shots}/rc_4_ranking.png`] : [])];
const run = await page("?lang=ja", ["--net", "/v1/", "--wait", "9", "--keys", keys.join(","), "--timeout", "260"]);
const net = {};
for (const l of run.filter((x) => x.startsWith("NET "))) net[l] = (net[l] || 0) + 1;
console.log("    API calls seen by the browser: " + Object.entries(net).map(([k, n]) => `${k.slice(4)} x${n}`).join(", "));
await sleep(1500);
const subs = (await s.DB.prepare("SELECT status, reason, score, wave, fp, build, platform FROM submissions").all()).results;
const board = await (await fetch(s.url + "/v1/top")).json();
console.log("    submissions: " + JSON.stringify(subs.map((x) => [x.status, x.reason, x.score, x.wave])));
console.log("    board: " + JSON.stringify(board.entries.map((e) => [e.rank, e.name, e.score, e.wave])));
expect("the run was started as a ranked run and sent", (net["NET 200 /v1/run/start"] || 0) >= 1 && (net["NET 200 /v1/submit"] || 0) >= 1);
expect("the replay was verified by the local verifier", subs.length >= 1 && subs.some((x) => x.status === "verified"));
expect("the replay carries build 3 and this build's fingerprint", subs.length >= 1 && subs.every((x) => x.build === 3 && String(x.fp) === fp && x.platform === 1));
expect("the board shows the Japanese name, the score and rank 1", board.entries.length === 1 && board.entries[0].name === "候補太郎" && board.entries[0].rank === 1 && board.entries[0].score > 0);
await v.stop();
await s.close();
console.log(`rc check: ${total} checks, ${failed} failed`);
process.exit(failed ? 1 : 0);
