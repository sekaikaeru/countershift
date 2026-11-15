#!/usr/bin/env node
// Touch-control check. Headless Chrome pretends to be a phone (screen size,
// pixel ratio, touch events) and plays build/web-test-local, whose API address is the local mock
// started here (127.0.0.1:8784). Nothing talks to the production API.
//   1. controls: every finger gesture must turn into the expected key presses (the game logs them)
//   2. other screen sizes: buttons are found where the layout says, screenshots for the eye
//   3. a whole ranked run by touch only: start, play, die, type a name, OK button, local verifier
//   5. wording: keyboard words before the first touch, touch words after it (English and Japanese), and
//      back to the keyboard words and no touch buttons once a real key is pressed
// Usage: node tools/touch_check.mjs [--shots dir] [--only 1|2|3|5] [--build name] [--verifier-build dir]
// The build must be a test build (tools/build_web.sh http://127.0.0.1:8784 <name> WebTest): a release build has no touch log.
import { spawn } from "node:child_process";
import { gunzipSync } from "node:zlib";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "../server/dev.mjs";
import { startVerifier } from "../server/verifier.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (k) => { const i = process.argv.indexOf("--" + k); return i >= 0 ? process.argv[i + 1] : ""; };
// --build <name>: the build under build/ to test (default web-test-local, whose API is this mock)
const BUILD_DIR = join(HERE, "..", "build", arg("build") || "web-test-local");
const shots = arg("shots");
const only = arg("only");
if (shots) mkdirSync(shots, { recursive: true });
const env = { RATE_SALT: "touch-check-rate-salt-0123456789abcdef-0123", VERIFIER_TOKEN: "touch-check-verifier-token-0123456789abcdef", ADMIN_TOKEN: "touch-check-admin-token-0123456789abcdef-01" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let total = 0, failed = 0;
const expect = (what, ok) => { total++; if (!ok) failed++; console.log(`  ${ok ? "ok  " : "FAIL"}  ${what}`); return ok; };
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

// ---- the same arithmetic as scripts/touch.gd, to know where the buttons are
function geometry(w, h, dpr) {
  const scale = Math.min(w / 1280, h / 720);                       // CSS pixels per game unit
  const off = { x: (w - 1280 * scale) / 2, y: (h - 720 * scale) / 2 };
  const upc = clamp(1280 / Math.min(w * dpr, h * dpr * 16 / 9) * dpr, 0.6, 3);
  const bh = clamp(46 * upc, 58, 100), bw = bh * 1.45, m = 20, gap = 10;
  const by = 720 - m - bh, by2 = by - gap - bh, rx = 1280 - m;
  const c = (x, y, ww, hh) => ({ x: x + ww / 2, y: y + hh / 2, w: ww, h: hh });
  const ph = clamp(34 * upc, 44, 64);
  return { scale, off, upc, reach: 58 * upc, dead: 14 * upc, btn: {
    up: c(m, by2, bw, bh), down: c(m, by, bw, bh),
    left: c(rx - bw * 2 - gap, by2, bw, bh), right: c(rx - bw, by2, bw, bh),
    okTitle: c(rx - bw * 2 - gap, by, bw * 2 + gap, bh), okPause: c(rx - bw * 1.6, by, bw * 1.6, bh),
    back: c(rx - bw * 1.6, by, bw * 1.6, bh), pause: c(330, 10, ph * 1.25, ph),
    title: c(m, by, bw * 1.25, bh), retry: c(rx - bw * 1.25, by, bw * 1.25, bh),
    rank: c(rx - bw * 1.25, by2, bw * 1.25, bh), name: c(m, by2, bw * 1.25, bh),
    // ranking screen: one row along the bottom, from the right: back, name, my rank, refresh, down, up
    ...(() => { const h = Math.min(bh, 80), w = h * 1.45, y = 720 - 12 - h, at = (i) => c(rx - w - i * (w + gap), y, w, h);
      return { rkBack: at(0), rkName: at(1), rkMine: at(2), rkRefresh: at(3), rkDown: at(4), rkUp: at(5) }; })() } };
}

async function openPage(url, w, h, dpr) {
  const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const profile = mkdtempSync(join(tmpdir(), "cs-touch-"));
  const port = 9300 + Math.floor(Math.random() * 500);
  const proc = spawn(chrome, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run",
    "--no-default-browser-check", "--mute-audio", "--autoplay-policy=no-user-gesture-required", "--window-size=1400,1000", "--hide-scrollbars", "about:blank"], { stdio: "ignore" });
  let target = null;
  for (let i = 0; i < 80 && !target; i++) {
    await sleep(250);
    try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === "page"); } catch {}
  }
  if (!target) throw new Error("chrome did not start");
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  const lines = [], net = [], reqs = [];
  const send = (method, params = {}) => new Promise((res) => { const n = ++id; pending.set(n, res); ws.send(JSON.stringify({ id: n, method, params })); });
  ws.onmessage = (msg) => {
    const d = JSON.parse(msg.data);
    if (d.id && pending.has(d.id)) { pending.get(d.id)(d.result || d); pending.delete(d.id); return; }
    if (d.method === "Runtime.consoleAPICalled") lines.push(d.params.args.map((a) => a.value ?? a.description ?? "").join(" "));
    else if (d.method === "Runtime.exceptionThrown") lines.push("PAGE EXCEPTION: " + (d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text));
    else if (d.method === "Network.requestWillBeSent") reqs.push(d.params.request.method + " " + d.params.request.url);
    else if (d.method === "Network.responseReceived" && d.params.response.url.includes("/v1/")) net.push(`${d.params.response.status} ${new URL(d.params.response.url).pathname}`);
  };
  await new Promise((r) => (ws.onopen = r));
  await send("Runtime.enable"); await send("Page.enable"); await send("Network.enable");
  let g = geometry(w, h, dpr);
  const metrics = async (ww, hh, d) => {
    await send("Emulation.setDeviceMetricsOverride", { width: ww, height: hh, deviceScaleFactor: d, mobile: true,
      screenOrientation: ww >= hh ? { type: "landscapePrimary", angle: 90 } : { type: "portraitPrimary", angle: 0 } });
    g = geometry(ww, hh, d);
  };
  await metrics(w, h, dpr);
  await send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
  await send("Emulation.setEmitTouchEventsForMouse", { enabled: false });
  await send("Page.navigate", { url });
  const fingers = new Map();                                       // finger id -> position in CSS pixels
  const pts = () => [...fingers].map(([fid, p]) => ({ x: Math.round(p.x), y: Math.round(p.y), id: fid, radiusX: 8, radiusY: 8, force: 1 }));
  const css = (ux, uy) => ({ x: g.off.x + ux * g.scale, y: g.off.y + uy * g.scale });      // game units -> CSS pixels
  const page = {
    lines, net, reqs, send, get g() { return g; }, metrics,
    mark: () => lines.length,
    since: (from, re) => lines.slice(from).filter((l) => re.test(l)),
    waitFor: async (re, ms, from = 0) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (lines.slice(from).some((l) => re.test(l))) return true; await sleep(150); } return false; },
    down: async (fid, ux, uy) => { fingers.set(fid, css(ux, uy)); await send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: pts() }); await sleep(90); },
    move: async (fid, ux, uy) => { fingers.set(fid, css(ux, uy)); await send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: pts() }); await sleep(90); },
    // lifting a finger: touchEnd names the finger that ends (checked on a blank page: the others stay down)
    up: async (fid) => { const q = fingers.get(fid); fingers.delete(fid); if (q) await send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [{ x: Math.round(q.x), y: Math.round(q.y), id: fid }] }); await sleep(90); },
    cancel: async () => { fingers.clear(); await send("Input.dispatchTouchEvent", { type: "touchCancel", touchPoints: [] }); await sleep(120); },
    tap: async (b, hold = 110) => { await page.down(9, b.x, b.y); await sleep(hold); await page.up(9); await sleep(140); },
    tapCss: async (x, y) => { const q = [{ x: Math.round(x), y: Math.round(y), id: 8, radiusX: 8, radiusY: 8, force: 1 }]; await send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [...pts(), ...q] }); await sleep(100); await send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: q }); await sleep(200); },
    js: async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true })).result?.value,
    shot: async (name) => { if (!shots) return; const r = await send("Page.captureScreenshot", { format: "png" }); writeFileSync(join(shots, name + ".png"), Buffer.from(r.data, "base64")); },
    close: async () => { try { proc.kill(); } catch {} await sleep(400); try { rmSync(profile, { recursive: true, force: true }); } catch {} },
  };
  return page;
}

const s = await startServer({ port: 8784, memory: true, env, quiet: true, webDir: BUILD_DIR });
const keys = (p, from) => p.since(from, /^TOUCHKEY /).map((l) => l.slice(9)).join(", ");
const boot = async (p) => { const ok = await p.waitFor(/^boot: sound ready/, 120000); await sleep(3500); return ok; };

if (!only || only === "1") {
  console.log("1. controls on a phone-sized screen (844x390, pixel ratio 3)");
  const p = await openPage(`${s.url}/?lang=en&touchlog=1`, 844, 390, 3);
  expect("the game starts", await boot(p));
  expect("no touch UI before the first touch (no key, no wake-up, keyboard wording)", p.since(0, /^TOUCH(KEY| active| state| asleep)/).length === 0 && (p.since(0, /^TOUCH words/)[0] || "").includes("touch=false"));
  await p.shot("p1_title_before_touch");
  let m = p.mark();
  await p.tap(p.g.btn.down); await p.tap(p.g.btn.up);
  const act = p.since(0, /^TOUCH active/)[0] || "";
  console.log("    " + act + "   (expected upc " + p.g.upc.toFixed(2) + ")");
  expect("the layer wakes at the first touch and measures the same finger size as this test", act.includes("upc=" + p.g.upc.toFixed(2)) && act.includes("portrait=false"));
  expect("title: the arrow buttons send Down and Up", keys(p, m) === "Down down, Down up, Up down, Up up");
  await p.shot("p1_title_touch");
  m = p.mark();
  await p.tap(p.g.btn.okTitle);
  expect("title: OK sends Enter", keys(p, m) === "Enter down, Enter up");
  await sleep(1200);
  m = p.mark();
  await p.down(1, 300, 500); await p.move(1, 400, 500);
  expect("stick right -> Right", keys(p, m) === "Right down");
  m = p.mark(); await p.move(1, 380, 580);
  expect("stick down-right -> Right stays, Down is added", keys(p, m) === "Down down");
  m = p.mark(); await p.move(1, 300, 380);
  expect("stick up -> Right and Down are let go, Up is pressed", keys(p, m) === "Right up, Down up, Up down");
  m = p.mark(); await p.down(2, 1000, 400);
  expect("a second finger on the right half -> Shift (while the stick is held)", keys(p, m) === "Shift down");
  await p.shot("p1_play_stick_and_shift");
  m = p.mark(); await p.up(2);
  let got = keys(p, m);
  expect(`lifting it -> Shift released, the stick stays held (got: ${got || "nothing"})`, got === "Shift up");
  m = p.mark(); await p.up(1);
  got = keys(p, m);
  expect(`lifting the stick finger -> Up released (got: ${got || "nothing"})`, got === "Up up");
  m = p.mark(); await p.down(1, 320, 520); await p.move(1, 322, 524); await p.up(1);
  expect("a tiny movement inside the dead zone sends nothing", keys(p, m) === "");
  m = p.mark(); await p.down(3, 1000, 300); await p.down(1, 300, 500); await p.move(1, 200, 500); await p.cancel();
  expect("a cancelled touch lets go of everything", keys(p, m) === "Shift down, Left down, Left up, Shift up" || keys(p, m) === "Shift down, Left down, Shift up, Left up");
  m = p.mark(); await p.tap(p.g.btn.pause);
  expect("pause button -> Escape", keys(p, m) === "Escape down, Escape up");
  await sleep(500); await p.shot("p1_pause");
  m = p.mark(); await p.down(1, 300, 500); await p.move(1, 420, 500); await p.up(1);
  expect("while paused the stick does nothing", keys(p, m) === "");
  m = p.mark(); await p.tap(p.g.btn.okPause); await sleep(500);
  await p.down(1, 300, 500); await p.move(1, 180, 500); await p.up(1);
  expect("OK resumes, and the stick works again", keys(p, m) === "Enter down, Enter up, Left down, Left up");
  // rotation: upright pauses the game and asks to turn the phone
  m = p.mark(); await p.down(2, 1000, 400); await p.metrics(390, 844, 3); await sleep(1500);
  const rot = keys(p, m);
  expect("turning the phone upright lets go of Shift and pauses (Escape)", rot.startsWith("Shift down, Shift up, Escape down, Escape up"));
  await p.shot("p1_portrait");
  await p.cancel();
  m = p.mark(); await p.down(1, 300, 500); await p.up(1);
  expect("upright: touches are ignored", keys(p, m) === "");
  await p.metrics(844, 390, 3); await sleep(1500);
  m = p.mark(); await p.tap(p.g.btn.okPause); await sleep(500);
  await p.down(2, 1000, 400);
  expect("turned back: OK resumes and Shift works", keys(p, m) === "Enter down, Enter up, Shift down");
  // focus: the page losing focus must not leave a key stuck
  m = p.mark();
  await p.js("document.getElementById('canvas').blur(); window.dispatchEvent(new Event('blur')); 1");
  await sleep(900);
  const blur = keys(p, m);
  console.log("    after blur: " + (blur || "(nothing)"));
  expect("losing focus releases Shift", blur.includes("Shift up"));
  expect("the page's own gestures are off (no scrolling, no zoom)", (await p.js("getComputedStyle(document.body).touchAction + '|' + document.querySelector('meta[name=viewport]').content")).startsWith("none|") && (await p.js("window.scrollY + '|' + (window.visualViewport ? window.visualViewport.scale : 1)")) === "0|1");
  expect("no page error", !p.lines.some((l) => l.startsWith("PAGE EXCEPTION") || l.includes("SCRIPT ERROR")));
  await p.close();
}

if (!only || only === "2") {
  console.log("2. other screens");
  for (const [name, w, h, dpr] of [["iphone-se", 667, 375, 2], ["pixel-7", 915, 412, 2.625], ["ipad-air", 1180, 820, 2], ["small-android", 640, 360, 2]]) {
    const p = await openPage(`${s.url}/?lang=ja&touchlog=1`, w, h, dpr);
    await boot(p);
    let m = p.mark();
    await p.tap(p.g.btn.down); await p.tap(p.g.btn.up);
    const act = p.since(0, /^TOUCH active/)[0] || "";
    await p.shot(`p2_${name}_title`);
    const a = keys(p, m);
    m = p.mark(); await p.tap(p.g.btn.okTitle); await sleep(1500);
    await p.down(1, 280, 480); await p.move(1, 400, 480); await p.down(2, 1040, 420);
    await sleep(400); await p.shot(`p2_${name}_play`);
    const b = keys(p, m);
    await p.up(2); await p.up(1);
    m = p.mark(); await p.tap(p.g.btn.pause); await sleep(400); await p.shot(`p2_${name}_pause`);
    const c = keys(p, m);
    expect(`${name} ${w}x${h}@${dpr}: finger size ${p.g.upc.toFixed(2)} units/px, buttons ${Math.round(p.g.btn.up.h * p.g.scale)} px high; arrows, OK, stick, Shift and pause all answer`,
      act.includes("upc=" + p.g.upc.toFixed(2)) && a === "Down down, Down up, Up down, Up up" && b === "Enter down, Enter up, Right down, Shift down" && c === "Escape down, Escape up");
    await p.close();
  }
}

if (!only || only === "3") {
  console.log("3. a ranked run by touch only, verified by the local verifier");
  let ready = "";
  // --verifier-build <dir>: let another build do the verifying (for example a copy of the published one), to see
  // whether a run played by touch in this build is accepted by the verifier the ranking really uses
  const VB = arg("verifier-build") || BUILD_DIR;
  if (VB !== BUILD_DIR) console.log("    verifier runs a different build: " + VB);
  const v = await startVerifier({ buildDir: VB, api: s.url, token: env.VERIFIER_TOKEN, poll: 1, log: (t) => { if (t.includes("READY")) ready = t; if (t.includes("VERIFIED")) console.log("    " + t); } });
  await v.whenReady;
  console.log("    " + ready);
  const fp = (ready.match(/fp (\d+)/) || [])[1];
  expect("the verifier computes build 3 and the published fingerprint 1054582254", ready.includes("build 3") && fp === "1054582254");
  const p = await openPage(`${s.url}/?lang=ja&touchlog=1`, 844, 390, 3);
  await boot(p);
  await p.tap(p.g.btn.okTitle);
  await sleep(2500);
  // play: Shift taps with the right thumb and short pushes of the stick with the left, until the run ends.
  // A run that scores nothing is not sent (no name is asked): then RETRY is tapped and another run is played.
  const dirs = [[120, 0], [85, 85], [0, 120], [-85, 85], [-120, 0], [-85, -85], [0, -120], [85, -85]];
  let opened = false, runs = 0;
  const t0 = Date.now();
  while (!opened && runs < 5 && Date.now() - t0 < 420000) {
    runs++;
    const from = p.mark();
    for (let i = 0; Date.now() - t0 < 420000 && p.since(from, /^TOUCH state 5/).length === 0; i++) {
      if (i % 6 === 0) { const d = dirs[Math.floor(i / 6) % 8]; await p.down(1, 300, 470); await p.move(1, 300 + d[0], 470 + d[1]); }
      await p.down(2, 1000, 420); await sleep(60); await p.up(2);
      if (i % 6 === 3) await p.up(1);
      await sleep(60);
    }
    await p.cancel();
    for (let k = 0; k < 14 && !opened; k++) { await sleep(500); opened = await p.js("!!(window.__csName && window.__csName.open)"); }
    console.log(`    run ${runs}: ended after ${Math.round((Date.now() - t0) / 1000)} s in all, name window ${opened ? "opened" : "not opened (a run without score is not sent)"}`);
    if (!opened) { await p.shot(`p3_result_run${runs}`); await p.tap(p.g.btn.retry); await sleep(2500); }
  }
  await p.cancel();
  expect(`a run with a score ended and the name window opened (${runs} run(s), ${Math.round((Date.now() - t0) / 1000)} s)`, opened);
  const logged = p.since(0, /^TOUCHKEY /).map((l) => l.slice(9));
  expect("the stick and Shift were really used during the run", ["Left down", "Right down", "Up down", "Down down", "Shift down"].every((k) => logged.includes(k)));
  await sleep(800);
  const st0 = await p.js("JSON.stringify((function(){var s=window.__csName,r=s.el.getBoundingClientRect(),b=document.querySelectorAll('button');var o=b[0].getBoundingClientRect(),c=b[1].getBoundingClientRect();return {coarse:s.coarse,top:s.top,font:parseFloat(s.el.style.fontSize),inp:[r.left,r.top,r.width,r.height],ok:[o.left,o.top,o.width,o.height],cancel:[c.left,c.top,c.width,c.height],vw:innerWidth,vh:innerHeight}})())");
  const st = JSON.parse(st0);
  console.log("    name field: " + st0);
  expect("touch device detected: the field has OK and cancel buttons, inside the screen", st.coarse && st.ok[2] > 40 && st.ok[1] + st.ok[3] <= st.vh && st.cancel[0] + st.cancel[2] <= st.vw && st.inp[0] >= 0 && st.inp[1] >= 0);
  expect("the field's font is 16px or more (iOS would zoom the page otherwise)", st.font >= 16);
  {
    // game units -> CSS pixels: the notes end at 438, the window's frame at 562 (scripts/ui.gd _name_modal)
    const yy = (u) => p.g.off.y + u * p.g.scale, mid = (st.ok[0] + st.cancel[0] + st.cancel[2]) / 2;
    console.log(`    buttons: top ${st.ok[1].toFixed(1)} bottom ${(st.ok[1] + st.ok[3]).toFixed(1)}; notes end at ${yy(438).toFixed(1)}, window ends at ${yy(562).toFixed(1)}; field ends at ${(st.inp[1] + st.inp[3]).toFixed(1)}`);
    expect("OK and cancel sit under the notes and inside the window (no overlap with the notes or the field)",
      st.ok[1] >= yy(438) && st.cancel[1] >= yy(438) && st.ok[1] + st.ok[3] <= yy(562) && st.ok[1] >= st.inp[1] + st.inp[3] && st.ok[0] + st.ok[2] <= st.cancel[0]);
    expect("the two buttons are centred under the field", Math.abs(mid - (st.inp[0] + st.inp[2] / 2)) <= 3);
  }
  await p.tapCss(st.inp[0] + st.inp[2] / 2, st.inp[1] + st.inp[3] / 2);
  await p.send("Input.insertText", { text: "すまほ太郎" });
  await sleep(400);
  await p.shot("p3_name_typed");
  const m = p.mark();
  await p.tapCss(st.ok[0] + st.ok[2] / 2, st.ok[1] + st.ok[3] / 2);
  await sleep(14000);
  await p.shot("p3_result");
  expect("the name was accepted without any key event from the game layer", p.since(m, /^TOUCHKEY /).length === 0 && !(await p.js("window.__csName.open")));
  await p.tap(p.g.btn.rank); await sleep(3500);
  await p.shot("p3_ranking");
  {
    let k = p.mark(); await p.tap(p.g.btn.rkRefresh); await sleep(1500);
    const a = keys(p, k); k = p.mark(); await p.tap(p.g.btn.rkMine); await sleep(300);
    const b = keys(p, k); k = p.mark(); await p.tap(p.g.btn.rkDown); await p.tap(p.g.btn.rkUp);
    const c2 = keys(p, k);
    expect("ranking: REFRESH, MY RANK and the arrows send R, M, Down and Up", a === "R down, R up" && b === "M down, M up" && c2 === "Down down, Down up, Up down, Up up");
  }
  const mb = p.mark();
  await p.tap(p.g.btn.rkBack); await sleep(800);
  expect("ranking: BACK sends Escape", keys(p, mb) === "Escape down, Escape up");
  const netc = {};
  for (const l of p.net) netc[l] = (netc[l] || 0) + 1;
  console.log("    API calls: " + Object.entries(netc).map(([k, n]) => `${k} x${n}`).join(", "));
  const subs = (await s.DB.prepare("SELECT status, reason, score, wave, fp, build, platform, frames, replay FROM submissions").all()).results;
  const board = await (await fetch(s.url + "/v1/top")).json();
  console.log("    submissions: " + JSON.stringify(subs.map((x) => [x.status, x.reason, x.score, x.wave, x.frames])));
  console.log("    board: " + JSON.stringify(board.entries.map((e) => [e.rank, e.name, e.score, e.wave])));
  expect("the run was a ranked run and was sent", (netc["200 /v1/run/start"] || 0) >= 1 && (netc["200 /v1/submit"] || 0) >= 1);
  expect("the local verifier replayed it and got the same score (verified)", subs.length === 1 && subs[0].status === "verified" && subs[0].score > 0);
  expect("the replay carries build 3, platform 1 and the published fingerprint", subs.length === 1 && subs[0].build === 3 && subs[0].platform === 1 && String(subs[0].fp) === "1054582254");
  if (subs.length === 1) {
    const raw = gunzipSync(Buffer.from(subs[0].replay, "base64"));
    const n = Math.floor((raw.length - 28) / 9);
    let moved = 0, shift = 0, taps = 0, other = 0;
    for (let i = 0; i < n; i++) {
      const b = raw[28 + i * 9 + 8];
      if ((b & 15) !== 5) moved++;
      if (b & 16) shift++;
      if (b & 32) taps++;
      if (b & 192) other++;
    }
    console.log(`    replay: ${n} frames, ${moved} with a direction, ${shift} with Shift, ${taps} aim taps, format byte ${raw[4]}`);
    expect("the replay is the ordinary keyboard format: only direction, Shift and aim-tap bits", n > 100 && moved > 0 && shift > 0 && other === 0);
  }
  expect("the board shows the name, the score and rank 1", board.entries.length === 1 && board.entries[0].name === "すまほ太郎" && board.entries[0].rank === 1);
  expect("no page error", !p.lines.some((l) => l.startsWith("PAGE EXCEPTION") || l.includes("SCRIPT ERROR")));
  await p.close();
  await v.stop();
}
if (!only || only === "5") {
  console.log("5. wording: keyboard words until the first touch, touch words after it, keyboard words again after a real key");
  const KEYWORDS = /ENTER|ESC|TAB|WASD|SPACE|arrow keys|矢印キー|SHIFT を押す|HOLD SHIFT/;
  const want = { en: { hint1: "RIGHT side of the screen", hint2: "left stick", how1: "Left side of the screen", note: "return to the centre", tip: "Centre the stick", name: "Tap NAME" },
    ja: { hint1: "画面の右側を押し続ける", hint2: "左のスティック", how1: "画面の左側", note: "中央に戻して", tip: "中央に戻して", name: "「名前」を押して" } };
  for (const [lang, w, h, d] of [["en", 844, 390, 3], ["ja", 844, 390, 3], ["en", 640, 360, 2], ["ja", 640, 360, 2]]) {
    const tag = `${lang}_${w}x${h}`;
    const p = await openPage(`${s.url}/?lang=${lang}&touchlog=1`, w, h, d);
    await boot(p);
    const words = () => p.since(0, /^TOUCH words/).slice(-1)[0] || "";
    const part = (line, k) => (line.match(new RegExp(k + "=\\[([^\\]]*)\\]")) || [])[1];
    const w0 = words();
    expect(`${tag}: before any touch the keyboard words are used (ENTER, SHIFT, arrow keys)`, w0.includes("touch=false") && /ENTER/.test(part(w0, "nav")) && /SHIFT/.test(part(w0, "hint1")) && p.since(0, /^TOUCH active/).length === 0);
    await p.shot(`p5_${tag}_1_title_keyboard`);
    await p.tap(p.g.btn.down);
    const w1 = words(), x = want[lang];
    console.log("    " + w1.slice(0, 150) + " ...");
    expect(`${tag}: after a touch the key-only lines are hidden (menu, how-to, result, ranking)`, w1.includes("touch=true") && ["nav", "r_nav", "rk_nav", "how_back"].every((k) => part(w1, k) === ""));
    expect(`${tag}: stick on the left, hold on the right, and "centre the stick, push again" are explained`,
      part(w1, "hint1").includes(x.hint1) && part(w1, "hint2").includes(x.hint2) && part(w1, "how1_b").includes(x.how1) && part(w1, "how_note").includes(x.note) && part(w1, "tip4").includes(x.tip) && part(w1, "on_need_name").includes(x.name));
    expect(`${tag}: no key names are left in the touch wording`, !KEYWORDS.test(w1.split("|").slice(1).join("|")));
    await p.shot(`p5_${tag}_2_title_touch`);
    await p.tap(p.g.btn.okTitle); await sleep(900);                 // the menu is on HOW TO PLAY now
    await p.shot(`p5_${tag}_3_howto_touch`);
    let m = p.mark();
    await p.tap(p.g.btn.back); await sleep(700);
    await p.tap(p.g.btn.up); await p.tap(p.g.btn.okTitle); await sleep(1800);
    await p.shot(`p5_${tag}_4_play_hint_hold`);
    await p.down(2, 1000, 420); await sleep(700);
    await p.shot(`p5_${tag}_5_play_hint_aim`);
    await p.up(2);
    await p.tap(p.g.btn.pause); await sleep(500);
    await p.shot(`p5_${tag}_6_pause_touch`);
    m = p.mark();
    const kd = { key: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40 };
    await p.send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...kd }); await sleep(90);
    await p.send("Input.dispatchKeyEvent", { type: "keyUp", ...kd }); await sleep(500);
    const w2 = p.since(m, /^TOUCH words/).slice(-1)[0] || "";
    expect(`${tag}: a real key puts the touch buttons away and brings the keyboard words back`, p.since(m, /^TOUCH asleep/).length === 1 && w2.includes("touch=false") && /ENTER/.test(part(w2, "nav")));
    await p.shot(`p5_${tag}_7_pause_keyboard`);
    m = p.mark();
    await p.tap(p.g.btn.up); await sleep(300);
    const w3 = p.since(m, /^TOUCH words/).slice(-1)[0] || "";
    expect(`${tag}: the next touch brings the touch controls and wording back`, p.since(m, /^TOUCH active/).length === 1 && w3.includes("touch=true"));
    expect(`${tag}: no page error`, !p.lines.some((l) => l.startsWith("PAGE EXCEPTION") || l.includes("SCRIPT ERROR")));
    await p.close();
  }
}
await s.close();
console.log(`touch check: ${total} checks, ${failed} failed`);
process.exit(failed ? 1 : 0);
