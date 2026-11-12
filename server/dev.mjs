#!/usr/bin/env node
// Local ranking server: the real worker code on a local SQLite file, plus the Web build
// of the game on the same address, plus the verifier. Nothing leaves this machine.
//
//   node server/dev.mjs            -> http://127.0.0.1:8787/  (game + ranking)
//   node server/dev.mjs --no-verifier --port 8787 --memory
import http from "node:http";
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import worker from "./src/worker.js";
import { openLocalD1 } from "./src/d1-local.mjs";
import { startVerifier } from "./verifier.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, "..", "build", "web");
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".wasm": "application/wasm", ".pck": "application/octet-stream", ".png": "image/png", ".txt": "text/plain; charset=utf-8" };

function loadSecrets() {
  // local-only secrets, generated on first start and kept out of git
  const file = join(HERE, ".dev.vars");
  if (!existsSync(file)) {
    const mk = () => randomBytes(24).toString("hex");
    writeFileSync(file, `RATE_SALT=${mk()}\nVERIFIER_TOKEN=${mk()}\nADMIN_TOKEN=${mk()}\n`, { mode: 0o600 });
  }
  const out = {};
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) out[m[1]] = m[2].trim();
  }
  return out;
}

export async function startServer({ port = 8787, memory = false, dbFile: dbPath = "", serveGame = true, env = null, quiet = false, delayMs = 0, onReport = null, webDir = WEB } = {}) {
  let dbFile = ":memory:";
  if (dbPath) dbFile = dbPath;
  else if (!memory) {
    mkdirSync(join(HERE, "data"), { recursive: true });
    dbFile = join(HERE, "data", "local.sqlite");
  }
  const DB = openLocalD1(dbFile, join(HERE, "schema.sql"));
  const fullEnv = { DB, ...(env || loadSecrets()) };
  const state = { delayMs, down: false };
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, `http://${req.headers.host}`);
      if (onReport && url.pathname === "/__report" && req.method === "POST") {
        // test hook: pages opened with ?report=1 post their result lines here
        const chunks = [];
        for await (const c of req) chunks.push(c);
        onReport(Buffer.concat(chunks).toString("utf8"), req.headers["user-agent"] || "");
        res.writeHead(204, { "access-control-allow-origin": "*" });
        res.end();
        return;
      }
      if (url.pathname.startsWith("/v1/")) {
        if (state.down) { req.socket.destroy(); return; }
        if (state.delayMs) await new Promise((r) => setTimeout(r, state.delayMs));
        const chunks = [];
        for await (const c of req) chunks.push(c);
        const request = new Request(url, { method: req.method, headers: req.headers, body: ["GET", "HEAD", "OPTIONS"].includes(req.method) ? undefined : Buffer.concat(chunks) });
        const r = await worker.fetch(request, fullEnv);
        res.writeHead(r.status, Object.fromEntries(r.headers));
        res.end(Buffer.from(await r.arrayBuffer()));
        if (!quiet && req.method !== "OPTIONS" && url.pathname !== "/v1/verify/next" && url.pathname !== "/v1/submission") console.log(`${req.method} ${url.pathname} -> ${r.status}`);
        return;
      }
      if (!serveGame) { res.writeHead(404); res.end(); return; }
      const rel = normalize(url.pathname === "/" ? "/index.html" : url.pathname);
      const file = join(webDir, rel);
      if (!file.startsWith(webDir) || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); res.end("not found"); return; }
      res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream", "cache-control": "no-store" });
      createReadStream(file).pipe(res);
    } catch (e) {
      res.writeHead(500); res.end("error");
      console.error(e);
    }
  });
  await new Promise((ok, bad) => { server.once("error", bad); server.listen(port, "127.0.0.1", ok); });
  return { server, env: fullEnv, DB, state, url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => { try { DB.raw.close(); } catch {} r(); }); }) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const has = (k) => process.argv.includes("--" + k);
  const val = (k, d) => { const i = process.argv.indexOf("--" + k); return i >= 0 ? process.argv[i + 1] : d; };
  const s = await startServer({ port: Number(val("port", "8787")), memory: has("memory") });
  console.log(`COUNTERSHIFT (game + local ranking): ${s.url}/`);
  if (!existsSync(join(WEB, "index.html"))) console.log("note: build/web is missing; export the Web build first");
  let v = null;
  if (!has("no-verifier")) {
    try {
      v = await startVerifier({ game: s.url + "/", token: s.env.VERIFIER_TOKEN, poll: 1 });
      console.log("verifier: headless Chrome is replaying submitted runs");
    } catch (e) {
      console.log("verifier NOT running (" + e.message + "): submitted runs will stay unverified and off the board");
    }
  }
  const bye = async () => { if (v) await v.stop(); process.exit(0); };
  process.on("SIGINT", bye);
  process.on("SIGTERM", bye);
}
