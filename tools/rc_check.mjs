#!/usr/bin/env node
// Release-candidate check on a local mock API. It serves build/web-rc-local (the candidate's twin:
// same sources and export preset, API address = this mock) on 127.0.0.1:8784 and
//   1. reads the build's fingerprint and two behaviour fingerprints in Chrome,
//   2. plays a run through real key presses only (a production build has no test options):
//      START, Shift taps until the shields are gone, the name typed through an IME composition,
//      Enter, then waits for the local verifier and opens the ranking.
// Nothing here talks to the production API.  Usage: node tools/rc_check.mjs [--shots dir] [--build name] [--verifier-build dir] [--no-resend]
// --no-resend: do not press S after the send (to measure how often a send gets no answer on the local server)
import { spawn } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "../server/dev.mjs";
import { startVerifier } from "../server/verifier.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const opt = (k) => { const i = process.argv.indexOf("--" + k); return i >= 0 ? process.argv[i + 1] : ""; };
const BUILD_DIR = join(HERE, "..", "build", opt("build") || "web-rc-local");     // --build <name under build/>
// --verifier-build <dir>: another build does the verifying (for example a copy of the published one)
const VERIFIER_DIR = opt("verifier-build") || BUILD_DIR;
const si = process.argv.indexOf("--shots");
const shots = si >= 0 ? process.argv[si + 1] : "";
if (shots) mkdirSync(shots, { recursive: true });        // (a missing folder used to break the key sequence at the first screenshot)
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
if (VERIFIER_DIR !== BUILD_DIR) console.log("    verifier runs a different build: " + VERIFIER_DIR);
const v = await startVerifier({ buildDir: VERIFIER_DIR, api: s.url, token: env.VERIFIER_TOKEN, poll: 1, log: (m) => { if (m.includes("READY")) ready = m; if (m.includes("VERIFIED")) console.log("    " + m); } });
await v.whenReady;
console.log("    " + ready);
expect("verifier and build agree on the fingerprint", ready.includes(`fp ${fp}`) && ready.includes("build 3"));

console.log("3. a run by key presses only: START, Shift taps, name through an IME composition, Enter");
// The blind Shift taps sometimes end a run with no score at all. Such a run is not sent and no name is asked:
// that is how the game is meant to work, not a failure. So the page reports whether the name window opened;
// if it did not, the attempt is set aside and another page plays again (5 attempts at most).
const probe = (word, js) => "js:" + encodeURIComponent(`console.log('${word} ' + (${js}))`).replace(/,/g, "%2C");
const taps = [];
for (let i = 0; i < 230; i++) taps.push("Shift", "wait330");
let run = [], opened = false, attempts = 0, noScore = 0;
while (!opened && attempts < 5) {
  attempts++;
  const sh = (n) => (shots ? [`shot:${shots}/rc_${n}${attempts > 1 ? "_try" + attempts : ""}.png`] : []);
  const keys = ["Enter", "wait2500", ...taps, "wait4500",
    probe("NAMEWIN", "!!(window.__csName && window.__csName.open)"),
    probe("TOUCHBAR", "(function(){var b=document.querySelector('button');return b?getComputedStyle(b.parentNode).display+'/'+window.__csName.coarse:'none/false'})()"),
    ...sh("1_name_window"),
    "compose:こうほ", "RealEnter", "wait300", "ime:こうほ>候補太郎", "wait300",
    probe("STILLOPEN", "!!(window.__csName && window.__csName.open)"),
    ...sh("2_name_typed"),
    // If the send got no answer (seen once: the local test server had just closed the idle connection the
    // browser reused), the game says "could not send, S: send again". S does that, and nothing otherwise.
    "RealEnter", "wait7000", ...sh("3a_after_send"), ...(process.argv.includes("--no-resend") ? [] : ["s"]), "wait9000",
    ...sh("3_result"),
    "Tab", "wait3500",
    ...sh("4_ranking")];
  run = await page("?lang=ja", ["--net", "/v1/", "--wait", "9", "--keys", keys.join(","), "--timeout", "260"]);
  opened = run.some((l) => l.trim() === "NAMEWIN true");
  if (!opened) { noScore++; console.log(`    attempt ${attempts}: the run ended without a score, so nothing was sent and no name was asked (as designed); playing again`); }
}
expect(`a run with a score was played within 5 attempts (${attempts} played, ${noScore} without a score)`, opened);
expect("keyboard player: the name window has no touch buttons", run.some((l) => l.trim() === "TOUCHBAR none/false"));
expect("the Enter that confirms the IME conversion does not decide the name (the window stays open)", run.some((l) => l.trim() === "STILLOPEN true"));
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
