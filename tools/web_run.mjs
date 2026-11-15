#!/usr/bin/env node
// Opens a URL in headless Chrome (own throwaway profile), prints the page console,
// and stops when a console line matches --until or after --timeout seconds.
// Optional: --shot <file.png> saves a screenshot at the end; --keys "Enter,ArrowDown" sends key taps.
// Usage: node tools/web_run.mjs <url> [--until REGEX] [--timeout 60] [--shot out.png] [--wait 3]
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const url = args[0];
const opt = (k, d) => { const i = args.indexOf("--" + k); return i >= 0 ? args[i + 1] : d; };
const until = opt("until", null) ? new RegExp(opt("until")) : null;
const timeout = Number(opt("timeout", "60")) * 1000;
const shot = opt("shot", null);
const wait = Number(opt("wait", "0")) * 1000;
const keys = opt("keys", "");
const size = opt("size", "1280,720");
const netHost = opt("net", null);
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const keep = opt("profile-dir", null);          // reuse a browser profile (saved data survives)
const profile = keep || mkdtempSync(join(tmpdir(), "cs-chrome-"));
const port = 9300 + Math.floor(Math.random() * 500);
const proc = spawn(chrome, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--mute-audio", "--autoplay-policy=no-user-gesture-required",
  `--window-size=${size}`, "--hide-scrollbars", "--force-device-scale-factor=1", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let done = false;
const sentAt = new Map();
const finish = async (code) => { if (done) return; done = true; try { proc.kill(); } catch {} await sleep(300); if (!keep) { try { rmSync(profile, { recursive: true, force: true }); } catch {} } process.exit(code); };

let target = null;
for (let i = 0; i < 60 && !target; i++) {
  await sleep(250);
  try { const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); target = list.find((t) => t.type === "page"); } catch {}
}
if (!target) { console.error("chrome did not start"); await finish(2); }
const ws = new WebSocket(target.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (method, params = {}) => new Promise((res) => { const n = ++id; pending.set(n, res); ws.send(JSON.stringify({ id: n, method, params })); });
let matched = false;
let until2 = null, matched2 = false;
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { pending.get(d.id)(d.result); pending.delete(d.id); return; }
  if (d.method === "Runtime.consoleAPICalled") {
    const text = d.params.args.map((a) => a.value ?? a.description ?? "").join(" ");
    console.log(text);
    if (until && until.test(text)) matched = true;
    if (until2 && until2.test(text)) matched2 = true;
  } else if (netHost && d.method === "Network.responseReceived" && d.params.response.url.includes(netHost)) {
    console.log(`NET ${d.params.response.status} ${new URL(d.params.response.url).pathname}`);
  } else if (netHost && d.method === "Network.requestWillBeSent" && d.params.request.url.includes(netHost) && d.params.request.method === "POST") {
    sentAt.set(d.params.requestId, new URL(d.params.request.url).pathname);       // POSTs only: to name the one that fails
  } else if (netHost && d.method === "Network.loadingFailed" && (!d.params.canceled || sentAt.has(d.params.requestId))) {
    console.log(`NET failed ${d.params.errorText}${d.params.canceled ? " (cancelled)" : ""}${sentAt.has(d.params.requestId) ? " POST " + sentAt.get(d.params.requestId) : ""}`);
  } else if (d.method === "Runtime.exceptionThrown") {
    console.log("PAGE EXCEPTION: " + (d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text));
  }
};
await new Promise((r) => (ws.onopen = r));
await send("Runtime.enable"); await send("Page.enable");
// --net <host part>: print the requests the page makes to hosts containing that text, with their status
if (netHost) await send("Network.enable");
await send("Page.navigate", { url });
const t0 = Date.now();
// "ime:かな>漢字" types like a Japanese IME: composition text grows, then the converted text is committed
const ime = async (spec) => {
  const [reading, result] = spec.slice(4).split(">");
  for (let i = 1; i <= reading.length; i++) {
    await send("Input.imeSetComposition", { text: reading.slice(0, i), selectionStart: i, selectionEnd: i });
    await sleep(120);
  }
  await send("Input.imeSetComposition", { text: result || reading, selectionStart: (result || reading).length, selectionEnd: (result || reading).length });
  await sleep(200);
  await send("Input.insertText", { text: result || reading });
  await sleep(250);
};
const tap = async (key) => {
  if (key.startsWith("ime:")) return ime(key);
  if (key.startsWith("click:")) {      // click:x:y in page pixels
    const [x, y] = key.slice(6).split(":").map(Number);
    await send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
    await send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
    await sleep(200); return;
  }
  if (key.startsWith("js:")) { await send("Runtime.evaluate", { expression: decodeURIComponent(key.slice(3)) }); await sleep(120); return; }
  if (key === "RealEnter") {   // as a keyboard sends it: keydown with the carriage return character, then keyup
    const base = { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 };
    await send("Input.dispatchKeyEvent", { type: "keyDown", ...base, text: "\r" }); await sleep(90);
    await send("Input.dispatchKeyEvent", { type: "keyUp", ...base }); await sleep(160); return;
  }
  if (key.startsWith("shot:")) { const r = await send("Page.captureScreenshot", { format: "png" }); writeFileSync(key.slice(5), Buffer.from(r.data, "base64")); return; }
  if (key.startsWith("compose:")) { const t = key.slice(8); await send("Input.imeSetComposition", { text: t, selectionStart: t.length, selectionEnd: t.length }); await sleep(300); return; }
  const map = { Enter: 13, Escape: 27, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Space: 32, Shift: 16, Tab: 9, Backspace: 8 };
  const isChar = key.length === 1;
  const code = isChar ? "Key" + key.toUpperCase() : (key === "Space" ? "Space" : key === "Shift" ? "ShiftLeft" : key);
  const vk = isChar ? key.toUpperCase().charCodeAt(0) : map[key];
  // No nativeVirtualKeyCode: with it, some keys (Shift, Space, and Enter with the macOS code) made
  // headless Chrome on macOS mark the page hidden and stop drawing. key/code/windowsVirtualKeyCode
  // are what the page sees.
  const base = { key: key === "Space" ? " " : key, code, windowsVirtualKeyCode: vk };
  await send("Input.dispatchKeyEvent", { type: isChar ? "keyDown" : "rawKeyDown", ...base, text: isChar ? key : undefined });
  await sleep(90);
  await send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
  await sleep(160);
};
let keysSent = keys === "";
while (Date.now() - t0 < timeout && !matched) {
  await sleep(200);
  if (!keysSent && Date.now() - t0 > wait) {
    keysSent = true;
    for (const k of keys.split(",")) { if (k.startsWith("wait")) await sleep(Number(k.slice(4))); else await tap(k); }
  }
  if (!until && keysSent && Date.now() - t0 > wait + 400 && keys === "" && wait > 0) break;
}
// optional second act: once the first pattern matched, press keys and wait for another line
const thenKeys = opt("then-keys", "");
const thenUntil = opt("then-until", null) ? new RegExp(opt("then-until")) : null;
const midShot = opt("mid-shot", null);
if (matched && thenKeys) {
  await sleep(Number(opt("then-wait", "5")) * 1000);
  if (midShot) { const r = await send("Page.captureScreenshot", { format: "png" }); writeFileSync(midShot, Buffer.from(r.data, "base64")); }
  for (const k of thenKeys.split(",")) { if (k.startsWith("wait")) await sleep(Number(k.slice(4))); else await tap(k); }
  if (thenUntil) {
    until2 = thenUntil; matched2 = false;
    const t1 = Date.now();
    while (Date.now() - t1 < 60000 && !matched2) await sleep(200);
    if (!matched2) matched = false;
  }
}
const after = Number(opt("after", "0")) * 1000;   // keep the page open a little after the match
if (after) await sleep(after);
if (shot) {
  const r = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(shot, Buffer.from(r.data, "base64"));
  console.log("screenshot: " + shot);
}
await finish(until && !matched ? 1 : 0);
