#!/usr/bin/env node
// Verifier for Web runs. The Workers API cannot run the game (no browser, 10 ms CPU), so this
// runs next to it, on any machine with Chrome (a Mac is enough):
//
//   API (Workers + D1)  <── HTTPS, Bearer VERIFIER_TOKEN ──  this process
//                                                              └ headless Chrome (pipe, no port)
//                                                                 └ the game's Web build, ?verify=1
//
// The page asks the API for queued replays recorded with its own platform, build and fingerprint,
// replays them in the very build the players use and reports the real score. Nothing is pushed to
// this machine: if it is asleep or off, runs wait in D1 and are verified when it comes back (a lease
// that ran out while asleep is simply handed out again).
//
// Production (build/web-prod is the exact build that is published):
//   node server/verifier.mjs --prod --build-dir build/web-prod --api https://<worker>.workers.dev
//   (--prod reads VERIFIER_TOKEN from server/.prod.secrets.json; it is never put on a command line)
// Local development uses --game <url> (server/dev.mjs does this for you).
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".wasm": "application/wasm", ".pck": "application/octet-stream", ".png": "image/png" };
const STALL_MS = 180_000;      // no sign of life from the page for this long: restart Chrome

/** sha256 of every file of a build, so the operator can compare with what is published. */
export function buildManifest(dir) {
  const h = createHash("sha256");
  for (const f of readdirSync(dir).sort()) {
    const p = join(dir, f);
    if (statSync(p).isFile()) h.update(f + "\0").update(readFileSync(p));
  }
  return h.digest("hex").slice(0, 16);
}

/** Serves one build directory on 127.0.0.1 only (the verifier's own copy of the game). */
export async function serveBuild(dir) {
  const root = resolve(dir);
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    const file = join(root, normalize(url.pathname === "/" ? "/index.html" : url.pathname));
    if (!file.startsWith(root) || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream", "cache-control": "no-store" });
    createReadStream(file).pipe(res);
  });
  await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
  return { url: `http://127.0.0.1:${server.address().port}/`, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }) };
}

/** Headless Chrome driven over a pipe (DevTools protocol on fds 3/4: nothing listens on a port). */
async function openChrome(url, onLine) {
  const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const profile = mkdtempSync(join(tmpdir(), "cs-verifier-"));
  const proc = spawn(chrome, ["--headless=new", "--remote-debugging-pipe", `--user-data-dir=${profile}`, "--no-first-run",
    "--no-default-browser-check", "--mute-audio", "--window-size=640,360", "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows", "about:blank"],
  { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
  const toChrome = proc.stdio[3], fromChrome = proc.stdio[4];
  let id = 0, buf = "";
  const pending = new Map();
  const send = (method, params = {}, sessionId) => new Promise((res) => {
    const n = ++id;
    pending.set(n, res);
    toChrome.write(JSON.stringify({ id: n, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
  });
  fromChrome.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\0")) >= 0) {
      const msg = JSON.parse(buf.slice(0, i));
      buf = buf.slice(i + 1);
      if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg.result || msg); pending.delete(msg.id); }
      else if (msg.method === "Runtime.consoleAPICalled") onLine(msg.params.args.map((a) => a.value ?? "").join(" "));
      else if (msg.method === "Runtime.exceptionThrown") onLine("PAGE EXCEPTION " + (msg.params.exceptionDetails?.exception?.description || ""));
    }
  });
  toChrome.on("error", () => {});
  let exited = false;
  const exitedPromise = new Promise((r) => proc.on("exit", () => { exited = true; r(); }));
  const close = async () => {
    try { proc.kill(); } catch {}
    await Promise.race([exitedPromise, sleep(2000)]);
    try { rmSync(profile, { recursive: true, force: true }); } catch {}
  };
  const targets = (await send("Target.getTargets")).targetInfos || [];
  const page = targets.find((t) => t.type === "page");
  if (!page) { await close(); throw new Error("headless Chrome did not open a page"); }
  const { sessionId } = await send("Target.attachToTarget", { targetId: page.targetId, flatten: true });
  await send("Runtime.enable", {}, sessionId);
  await send("Page.enable", {}, sessionId);
  await send("Page.navigate", { url }, sessionId);
  return { close, isExited: () => exited, pid: proc.pid };
}

/**
 * Starts the verifier and keeps it running: restarts Chrome when it exits or the page stalls.
 * game: URL of the game (or buildDir: serve that build locally); api: ranking API (default: the game's origin).
 */
export async function startVerifier({ game = "", buildDir = "", api = "", token, log = console.log, once = false, poll = 10, stallMs = STALL_MS }) {
  if (!token || token.length < 32) throw new Error("VERIFIER_TOKEN is missing or too short");
  let local = null;
  if (buildDir) {
    local = await serveBuild(buildDir);
    game = local.url;
    log(`[verifier] game build ${buildDir} (files ${buildManifest(buildDir)}) served on ${local.url}`);
  }
  const q = new URLSearchParams({ verify: "1", vtoken: token, vpoll: String(poll) });
  if (api) q.set("api", api);
  if (once) q.set("once", "1");
  const url = `${game}${game.includes("?") ? "&" : "?"}${q}`;
  let ready, idle;
  const whenReady = new Promise((r) => (ready = r));
  const whenIdle = new Promise((r) => (idle = r));
  let lastSign = Date.now();
  let stopped = false;
  let chrome = null;
  let starts = 0;
  const onLine = (text) => {
    if (text.startsWith("VERIFIER") || text.startsWith("VERIFIED")) lastSign = Date.now();
    if (text.startsWith("VERIFIER READY")) { log("[verifier] " + text); ready(text); }
    else if (text.startsWith("VERIFIED")) log("[verifier] " + text);
    else if (text.startsWith("VERIFIER IDLE")) idle();
    else if (text.startsWith("PAGE EXCEPTION")) log("[verifier] " + text);
  };
  const loop = async () => {
    let backoff = 2000;
    while (!stopped) {
      try {
        lastSign = Date.now();
        chrome = await openChrome(url, onLine);
        starts++;
        backoff = 2000;
        while (!stopped && !chrome.isExited() && Date.now() - lastSign < stallMs) await sleep(500);
        if (stopped) break;
        log(chrome.isExited() ? "[verifier] Chrome exited; restarting" : "[verifier] page stalled; restarting Chrome");
        await chrome.close();
      } catch (e) {
        log("[verifier] could not start Chrome: " + e.message);
      }
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 60_000);
    }
  };
  loop();
  const stop = async () => {
    stopped = true;
    if (chrome) await chrome.close();
    if (local) await local.close();
  };
  return { stop, whenReady, whenIdle, chromePid: () => chrome?.pid, starts: () => starts };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const arg = (k) => { const i = process.argv.indexOf("--" + k); return i >= 0 ? process.argv[i + 1] : ""; };
  let token = process.env.VERIFIER_TOKEN || "";
  if (!token && process.argv.includes("--prod")) token = (await import("../tools/make_secrets.mjs")).readSecret("VERIFIER_TOKEN");   // from server/.prod.secrets.json
  if ((!arg("game") && !arg("build-dir")) || token.length < 32) {
    console.error("usage: node server/verifier.mjs --prod --build-dir <dir> --api <url>   (or VERIFIER_TOKEN=... with --game <url>) [--poll 10]");
    process.exit(2);
  }
  const v = await startVerifier({ game: arg("game"), buildDir: arg("build-dir"), api: arg("api"), token, poll: Number(arg("poll") || "10") });
  const bye = async () => { await v.stop(); process.exit(0); };
  process.on("SIGINT", bye);
  process.on("SIGTERM", bye);
}
