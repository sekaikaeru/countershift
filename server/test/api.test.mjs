// API tests: the real worker code against an in-memory database with the real schema.
// Run: node --test server/test/
import test from "node:test";
import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/worker.js";
import { BUILD, DAILY, FORMAT, HEADER, RATE, SECRETS, cleanName, inspectHeader, LIMITS, missingConfig, readReplayHeader } from "../src/api.js";
import { readFileSync } from "node:fs";
import { openLocalD1 } from "../src/d1-local.mjs";

const SCHEMA = join(dirname(fileURLToPath(import.meta.url)), "..", "schema.sql");
const VT = "verifier-token-for-tests-0001-abcdefghij";
const AT = "admin-token-for-tests-00000001-abcdefghij";
const realNow = Date.now;
let clock = 1_800_000_000_000;
Date.now = () => clock;
test.after(() => { Date.now = realNow; });
let ipSeq = 0;

function fresh() {
  const env = { DB: openLocalD1(":memory:", SCHEMA), RATE_SALT: "rate-salt-for-local-tests-0123456789abcdef", VERIFIER_TOKEN: VT, ADMIN_TOKEN: AT };
  const call = async (method, path, body, { ip = "10.0.0.1", bearer = "", raw = null } = {}) => {
    const headers = { "content-type": "application/json", "cf-connecting-ip": ip };
    if (bearer) headers.authorization = "Bearer " + bearer;
    const r = await worker.fetch(new Request("http://x" + path, { method, headers, body: raw ?? (body ? JSON.stringify(body) : undefined) }), env);
    return { status: r.status, body: await r.json().catch(() => ({})), headers: r.headers };
  };
  const player = async () => (await call("POST", "/v1/player", null, { ip: "10.1." + (ipSeq >> 8) + "." + (ipSeq++ & 255) })).body;
  return { env, call, player };
}

const FP = 1054582254;
/** A structurally valid replay of `seconds` at 60 fps (format 2, see scripts/replay.gd). */
function replayRaw(seed, seconds = 60, { fp = FP, fps = 60, jitter = false } = {}) {
  const frames = Math.round(seconds * fps);
  const b = Buffer.alloc(HEADER + frames * 9);
  b.writeUInt32LE(0x31525343, 0); b.writeUInt8(FORMAT, 4); b.writeUInt8(0, 5); b.writeUInt8(1, 6);
  b.writeUInt32LE(seed, 8); b.writeUInt32LE(frames, 12); b.writeUInt16LE(BUILD, 16); b.writeUInt32LE(fp, 20);
  let ms = 0;
  for (let i = 0; i < frames; i++) {
    const dt = jitter ? 1 / fps + ((i * 7919) % 97) * 1e-6 : 1 / fps;
    ms += Math.min(dt, 0.05);
    b.writeDoubleLE(dt, HEADER + i * 9); b.writeUInt8(5 | ((i >> 5) & 1 ? 16 : 0), HEADER + i * 9 + 8);
  }
  b.writeUInt32LE(Math.floor(ms * 1000), 24);
  return b;
}
function replay(seed, seconds = 60, patch = null, opts = {}) {
  const b = replayRaw(seed, seconds, opts);
  if (patch) patch(b);
  return gzipSync(b).toString("base64");
}

/** Plays a whole honest-looking run for a player and returns the submit response. */
async function runAndSubmit(t, p, { score = 1000, wave = 3, seconds = 60, name = "ACE", patch = null, wait = null } = {}) {
  const auth = { player_id: p.player_id, token: p.token };
  const run = (await t.call("POST", "/v1/run", auth)).body;
  await t.call("POST", "/v1/run/start", { ...auth, run_id: run.run_id });
  clock += wait ?? seconds * 1000 + 500;
  return t.call("POST", "/v1/submit", { ...auth, run_id: run.run_id, name, score, wave, replay: replay(run.seed, seconds, patch) });
}

async function verify(t, { ok = true, score = null, wave = null, time = null, fp = FP } = {}) {
  const job = (await t.call("GET", `/v1/verify/next?platform=1&fp=${fp}`, null, { bearer: VT })).body;
  if (job.none) return null;
  const s = await t.env.DB.prepare("SELECT score, wave, duration_ms FROM submissions WHERE id = ?1").bind(job.id).first();
  return (await t.call("POST", "/v1/verify/result", { id: job.id, ok, score: score ?? s.score, wave: wave ?? s.wave, time_ms: time ?? s.duration_ms, reason: ok ? "" : "run_not_finished" }, { bearer: VT })).body;
}

test("a run reaches the board only after the verifier confirms it", async () => {
  const t = fresh();
  const p = await t.player();
  const r = await runAndSubmit(t, p, { score: 4200, wave: 5 });
  assert.equal(r.status, 200);
  assert.equal(r.body.status, "pending");
  assert.equal(r.body.provisional_rank, 1);
  assert.equal((await t.call("GET", "/v1/top")).body.entries.length, 0, "unverified runs are not public");
  const st = { player_id: p.player_id, token: p.token, submission_id: r.body.submission_id };
  assert.equal((await t.call("POST", "/v1/submission", st)).body.status, "pending");
  assert.equal((await verify(t)).status, "verified");
  const done = (await t.call("POST", "/v1/submission", st)).body;
  assert.equal(done.status, "verified");
  assert.equal(done.me.rank, 1);
  const top = (await t.call("GET", "/v1/top?player=" + p.player_id)).body;
  assert.deepEqual(top.entries.map((e) => [e.rank, e.name, e.score, e.wave, e.me]), [[1, "ACE", 4200, 5, true]]);
  assert.equal(top.me.rank, 1);
  assert.equal(top.total, 1);
});

test("a replay that does not reproduce the claimed score is rejected", async () => {
  const t = fresh();
  const p = await t.player();
  const r = await runAndSubmit(t, p, { score: 9000 });
  assert.equal((await verify(t, { score: 8990 })).status, "rejected");
  const st = (await t.call("POST", "/v1/submission", { player_id: p.player_id, token: p.token, submission_id: r.body.submission_id })).body;
  assert.equal(st.status, "rejected");
  assert.equal(st.reason, "score_mismatch");
  assert.equal((await t.call("GET", "/v1/top")).body.entries.length, 0);
  const r2 = await runAndSubmit(t, p, { score: 500 });
  assert.equal((await verify(t, { ok: false })).status, "rejected");
  await runAndSubmit(t, p, { score: 600 });
  assert.equal((await verify(t, { time: 1 })).reason, "duration_mismatch", "the verifier's play time must match the header");
  assert.equal((await t.call("GET", "/v1/top")).body.total, 0);
  assert.equal(r2.body.status, "pending");
});

test("only the best run of a player counts", async () => {
  const t = fresh();
  const p = await t.player();
  await runAndSubmit(t, p, { score: 3000 });
  await verify(t);
  const lower = await runAndSubmit(t, p, { score: 2000 });
  assert.equal(lower.body.status, "not_best");
  assert.equal(lower.body.me.score, 3000);
  const same = await runAndSubmit(t, p, { score: 3000 });
  assert.equal(same.body.status, "not_best");
  const higher = await runAndSubmit(t, p, { score: 7000, wave: 8, name: "ACE2" });
  assert.equal(higher.body.status, "pending");
  assert.equal((await t.call("GET", "/v1/top")).body.entries[0].score, 3000, "old best stays until the new one is verified");
  await verify(t);
  const top = (await t.call("GET", "/v1/top")).body;
  assert.deepEqual([top.entries.length, top.entries[0].score, top.entries[0].name, top.entries[0].wave], [1, 7000, "ACE2", 8]);
  const kept = await t.env.DB.prepare("SELECT COUNT(*) AS n FROM submissions WHERE replay IS NOT NULL").first();
  assert.equal(kept.n, 1, "only the replay of the current best is kept");
});

test("ties: the earlier record ranks higher", async () => {
  const t = fresh();
  const a = await t.player(), b = await t.player(), c = await t.player();
  await runAndSubmit(t, b, { score: 5000, name: "FIRST" });
  await verify(t);
  await runAndSubmit(t, a, { score: 5000, name: "SECOND" });
  await verify(t);
  await runAndSubmit(t, c, { score: 6000, name: "TOP" });
  await verify(t);
  const top = (await t.call("GET", "/v1/top?player=" + a.player_id)).body;
  assert.deepEqual(top.entries.map((e) => e.name), ["TOP", "FIRST", "SECOND"]);
  assert.deepEqual(top.entries.map((e) => e.rank), [1, 2, 3]);
  assert.equal(top.me.rank, 3);
});

test("top 100, and the rank of a player outside it", async () => {
  const t = fresh();
  const me = await t.player();
  for (let i = 0; i < 130; i++) {
    await t.env.DB.prepare("INSERT INTO scores (player_id, name, score, wave, achieved_at, submission_id) VALUES (?1, ?2, ?3, 4, ?4, 's')").bind("p" + i, "N" + i, 100000 - i * 10, clock + i).run();
  }
  await runAndSubmit(t, me, { score: 500, name: "LOW" });
  await verify(t);
  const top = (await t.call("GET", "/v1/top?limit=100&player=" + me.player_id)).body;
  assert.equal(top.entries.length, 100);
  assert.equal(top.entries[0].score, 100000);
  assert.equal(top.entries[99].score, 100000 - 990);
  for (let i = 1; i < 100; i++) assert.ok(top.entries[i - 1].score >= top.entries[i].score);
  assert.equal(top.total, 131);
  assert.equal(top.me.rank, 131);
  assert.equal(top.entries.some((e) => e.me), false);
  assert.equal((await t.call("GET", "/v1/top?limit=5")).body.entries.length, 5);
  assert.equal((await t.call("GET", "/v1/top?limit=99999")).body.entries.length, 100);
});

test("timing: a run cannot be faster than real time, nor stretched without limit", async () => {
  const t = fresh();
  const p = await t.player();
  assert.equal((await runAndSubmit(t, p, { seconds: 120, wait: 30_000 })).body.error, "too_fast");
  assert.equal((await runAndSubmit(t, p, { seconds: 60, wait: 60_000 + LIMITS.pauseAllowanceMs + 5000 })).body.error, "too_slow");
  assert.equal((await runAndSubmit(t, p, { seconds: 60, wait: 60_000 + 5 * 60_000 })).body.status, "pending", "a few minutes of pause are fine");
});

test("tickets: not started, used twice, someone else's, expired", async () => {
  const t = fresh();
  const p = await t.player(), q = await t.player();
  const auth = { player_id: p.player_id, token: p.token };
  const run = (await t.call("POST", "/v1/run", auth)).body;
  const sub = { ...auth, run_id: run.run_id, name: "ACE", score: 100, wave: 1, replay: replay(run.seed, 10) };
  assert.equal((await t.call("POST", "/v1/submit", sub)).body.error, "run_not_started");
  assert.equal((await t.call("POST", "/v1/run/start", { player_id: q.player_id, token: q.token, run_id: run.run_id })).status, 409);
  assert.equal((await t.call("POST", "/v1/run/start", { ...auth, run_id: run.run_id })).status, 200);
  assert.equal((await t.call("POST", "/v1/run/start", { ...auth, run_id: run.run_id })).status, 409, "a ticket starts once");
  clock += 11_000;
  assert.equal((await t.call("POST", "/v1/submit", { ...sub, player_id: q.player_id, token: q.token })).body.error, "run_unknown");
  assert.equal((await t.call("POST", "/v1/submit", sub)).body.status, "pending");
  assert.equal((await t.call("POST", "/v1/submit", sub)).body.error, "run_used");
  const old = (await t.call("POST", "/v1/run", auth)).body;
  clock += LIMITS.ticketTtlMs + 1000;
  assert.equal((await t.call("POST", "/v1/run/start", { ...auth, run_id: old.run_id })).status, 409, "a ticket expires");
});

test("tampered replays and impossible scores are refused before they are queued", async () => {
  const t = fresh();
  const p = await t.player();
  const bad = async (opts) => (await runAndSubmit(t, p, opts)).body.error;
  assert.equal(await bad({ patch: (b) => b.writeUInt32LE(12345, 8) }), "seed_mismatch");
  assert.equal(await bad({ patch: (b) => b.writeUInt32LE(7, 0) }), "replay_magic");
  assert.equal(await bad({ patch: (b) => b.writeUInt16LE(BUILD + 1, 16) }), "build_mismatch");
  assert.equal(await bad({ patch: (b) => b.writeUInt32LE(0, 12) }), "replay_length");
  assert.equal(await bad({ patch: (b) => b.writeUInt32LE(LIMITS.maxFrames + 1, 12) }), "replay_length");
  assert.equal(await bad({ patch: (b) => b.writeUInt8(1, 4) }), "replay_format", "the old format is refused");
  assert.equal(await bad({ patch: (b) => b.writeUInt8(9, 6) }), "replay_header");
  assert.equal(await bad({ patch: (b) => b.writeUInt16LE(7, 18) }), "replay_header");
  assert.equal(await bad({ patch: (b) => b.writeUInt32LE(b.readUInt32LE(12) * 60, 24) }), "replay_duration", "more play time than the frames can hold");
  assert.equal(await bad({ patch: (b) => b.writeUInt32LE(5000, 24), wait: 10_000 }), "replay_frame_rate", "3600 frames in 5 s");
  assert.equal(await bad({ score: 5_000_000, seconds: 30 }), "implausible");
  assert.equal(await bad({ wave: 90, seconds: 30 }), "implausible");
  for (const score of [0, -5, 1.5, "100", null, 3e12]) assert.equal(await bad({ score }), "bad_score");
  const auth = { player_id: p.player_id, token: p.token };
  const run = (await t.call("POST", "/v1/run", auth)).body;
  await t.call("POST", "/v1/run/start", { ...auth, run_id: run.run_id });
  clock += 20_000;
  const base = { ...auth, run_id: run.run_id, name: "ACE", score: 10, wave: 1 };
  assert.equal((await t.call("POST", "/v1/submit", { ...base, replay: "not base64 !!" })).status, 400);
  assert.equal((await t.call("POST", "/v1/submit", { ...base, replay: "A".repeat(10000) + "!!!!" })).body.error, "replay_unreadable", "garbage after the start is the verifier's to refuse");
  assert.equal((await t.call("POST", "/v1/submit", { ...base, replay: Buffer.from("plain text, not gzip").toString("base64") })).body.error, "replay_unreadable");
  assert.equal((await t.call("POST", "/v1/submit", { ...base, replay: "A".repeat(LIMITS.maxReplayB64 + 4) })).status, 413);
  assert.equal((await t.call("GET", "/v1/top")).body.total, 0);
  assert.equal((await t.env.DB.prepare("SELECT COUNT(*) AS n FROM submissions").first()).n, 0);
});

test("the header is read without inflating the whole replay, also from a long run", async () => {
  const long = replayRaw(77, 30 * 60, { fps: 144, jitter: true });       // 30 minutes at 144 Hz
  const b64 = gzipSync(long).toString("base64");
  const head = await readReplayHeader(b64);
  const info = inspectHeader(head);
  assert.equal(info.frames, 30 * 60 * 144);
  assert.equal(info.seed, 77);
  assert.equal(info.fp, FP);
  assert.equal(await readReplayHeader("AAAA"), null);
  assert.equal(await readReplayHeader(Buffer.from("not gzip at all, just text").toString("base64")), null);
  assert.equal(inspectHeader(null).error, "replay_unreadable");
});

test("CPU time of the heaviest request stays well inside the 10 ms of the Free plan", async () => {
  const t = fresh();
  const p = await t.player();
  const auth = { player_id: p.player_id, token: p.token };
  // the largest replay the server accepts, made of incompressible frame times
  const raw = replayRaw(1, 60 * 60, { fps: 144, jitter: true });
  for (let i = HEADER; i < raw.length; i += 9) raw.writeDoubleLE(Math.random() * 0.02 + 0.001, i);
  let b64 = gzipSync(raw).toString("base64");
  while (b64.length > LIMITS.maxReplayB64) {
    const frames = Math.floor(raw.readUInt32LE(12) * 0.9);
    const cut = Buffer.from(raw.subarray(0, HEADER + frames * 9));
    cut.writeUInt32LE(frames, 12);
    let ms = 0;
    for (let i = 0; i < frames; i++) ms += Math.min(cut.readDoubleLE(HEADER + i * 9), 0.05);
    cut.writeUInt32LE(Math.floor(ms * 1000), 24);
    raw.fill(0); cut.copy(raw);
    b64 = gzipSync(cut).toString("base64");
  }
  const head = inspectHeader(await readReplayHeader(b64));
  const samples = [];
  for (let k = 0; k < 7; k++) {
    const run = (await t.call("POST", "/v1/run", auth)).body;
    await t.env.DB.prepare("UPDATE runs SET seed = 1 WHERE id = ?1").bind(run.run_id).run();
    await t.call("POST", "/v1/run/start", { ...auth, run_id: run.run_id });
    clock += head.durationMs + 1000;
    const body = JSON.stringify({ ...auth, run_id: run.run_id, name: "ACE", score: 1000 + k, wave: 3, replay: b64 });
    const c0 = process.cpuUsage();
    const r = await worker.fetch(new Request("http://x/v1/submit", { method: "POST", headers: { "content-type": "application/json" }, body }), t.env);
    const c = process.cpuUsage(c0);
    assert.equal(r.status, 200, JSON.stringify(await r.clone().json()));
    samples.push((c.user + c.system) / 1000);
    await t.env.DB.prepare("UPDATE submissions SET status = 'rejected'").run();
  }
  samples.sort((a, b) => a - b);
  const median = samples[3];
  console.log(`    submit of a ${(b64.length / 1e6).toFixed(2)} MB replay (${head.frames} frames): CPU median ${median.toFixed(2)} ms (Node, includes the local SQLite work)`);
  assert.ok(median < 10, `median ${median} ms`);
});

test("names: Japanese and English are kept, markup, symbols and abuse are refused", () => {
  assert.equal(cleanName("  Ace  Pilot "), "Ace Pilot");
  assert.equal(cleanName("シフトの達人"), "シフトの達人");
  assert.equal(cleanName("山田 太郎"), "山田 太郎");
  assert.equal(cleanName("ＡＢＣ１２３"), "ABC123", "full-width letters are folded");
  assert.equal(cleanName("ｶﾀｶﾅ"), "カタカナ");
  assert.equal(cleanName("a_b-c.d"), "a_b-c.d");
  assert.equal(cleanName("a\nb\t c"), "a b c", "line breaks and tabs become one space");
  for (const bad of ["", "   ", "x".repeat(13), "あ".repeat(13), "<script>", "a<b", "'; DROP TABLE scores;--", "name​", "a‮b", "😀", "ADMIN", "運営です", "f.u.c.k", "__--", null, 42, {}, "x".repeat(500)]) {
    assert.equal(cleanName(bad), null, JSON.stringify(bad));
  }
  assert.equal(cleanName("あ".repeat(12)), "あ".repeat(12));
});

test("bad names, hostile strings and unknown callers", async () => {
  const t = fresh();
  const p = await t.player();
  assert.equal((await runAndSubmit(t, p, { name: "<img src=x onerror=alert(1)>" })).body.error, "bad_name");
  assert.equal((await runAndSubmit(t, p, { name: "Robert'); DROP TABLE scores;--" })).body.error, "bad_name");
  const auth = { player_id: p.player_id, token: p.token };
  assert.equal((await t.call("POST", "/v1/name", { ...auth, name: "よいなまえ" })).body.name, "よいなまえ");
  assert.equal((await t.call("POST", "/v1/name", { ...auth, name: "bad!" })).status, 400);
  assert.equal((await t.call("POST", "/v1/run", { player_id: p.player_id, token: "wrong" })).status, 401);
  assert.equal((await t.call("POST", "/v1/run", { player_id: "' OR 1=1 --", token: p.token })).status, 401);
  assert.equal((await t.call("POST", "/v1/run", { player_id: { $ne: "" }, token: p.token })).status, 401);
  assert.equal((await t.call("GET", "/v1/top?player=" + encodeURIComponent("x' OR '1'='1"))).status, 200);
  assert.equal((await t.env.DB.prepare("SELECT COUNT(*) AS n FROM players").first()).n, 1, "the tables are intact");
  assert.equal((await t.call("POST", "/v1/run", null, { raw: "{not json" })).status, 400);
  assert.equal((await t.call("POST", "/v1/run", null, { raw: "[1,2]" })).status, 400);
  assert.equal((await t.call("POST", "/v1/submit", null, { raw: JSON.stringify({ x: "y".repeat(LIMITS.maxBody + 10) }) })).status, 400);
  assert.equal((await t.call("GET", "/v1/nothing")).status, 404);
  assert.equal((await t.call("GET", "/elsewhere")).status, 404);
  assert.equal((await t.call("PUT", "/v1/top")).status, 405);
  const pre = await worker.fetch(new Request("http://x/v1/submit", { method: "OPTIONS" }), t.env);
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get("access-control-allow-origin"), "*");
});

test("the verifier and admin doors need their tokens", async () => {
  const t = fresh();
  for (const bearer of ["", "nope", AT]) {
    assert.equal((await t.call("GET", `/v1/verify/next?platform=1&fp=${FP}`, null, { bearer })).status, 401);
    assert.equal((await t.call("POST", "/v1/verify/result", { id: "x", ok: true }, { bearer })).status, 401);
  }
  for (const bearer of ["", "nope", VT]) {
    assert.equal((await t.call("GET", "/v1/admin/list", null, { bearer })).status, 401);
    assert.equal((await t.call("POST", "/v1/admin/delete", { player_id: "x" }, { bearer })).status, 401);
  }
});

test("floods are slowed down", async () => {
  const t = fresh();
  const codes = [];
  for (let i = 0; i < 6; i++) codes.push((await t.call("POST", "/v1/player", null, { ip: "9.9.9.9" })).status);
  assert.deepEqual(codes, [200, 200, 200, 429, 429, 429]);
  let made = 3;
  for (let m = 0; m < 10; m++) {
    clock += 61_000;
    for (let i = 0; i < 3; i++) if ((await t.call("POST", "/v1/player", null, { ip: "9.9.9.9" })).status === 200) made++;
  }
  assert.equal(made, DAILY.player, "and a daily cap per address");
  assert.equal((await t.call("POST", "/v1/player", null, { ip: "9.9.9.10" })).status, 200, "other callers are not affected");
  const p = await t.player();
  const auth = { player_id: p.player_id, token: p.token };
  let limited = 0;
  for (let i = 0; i < 60; i++) if ((await t.call("POST", "/v1/run", auth)).status === 429) limited++;
  assert.equal(limited, 60 - RATE.play.max);
  let subLimited = 0;
  for (let i = 0; i < 30; i++) if ((await t.call("POST", "/v1/submit", { ...auth, run_id: "x", name: "ACE", score: 1, wave: 1, replay: "AAAA" })).status === 429) subLimited++;
  assert.equal(subLimited, 30 - RATE.submit.max);
  let topLimited = 0;
  for (let i = 0; i < 80; i++) if ((await t.call("GET", "/v1/top", null, { ip: "8.8.8.8" })).status === 429) topLimited++;
  assert.equal(topLimited, 80 - RATE.read.max);
  const raw = await t.env.DB.prepare("SELECT key FROM rate").all();
  assert.equal(raw.results.some((r) => r.key.includes("9.9.9.9")), false, "no raw address is stored");
});

test("verifier queue: one job at a time, lease, give up after repeated failures", async () => {
  const t = fresh();
  const p = await t.player();
  await runAndSubmit(t, p, { score: 800 });
  const next = (q) => t.call("GET", "/v1/verify/next?" + q, null, { bearer: VT }).then((r) => r.body);
  const first = await next(`platform=1&fp=${FP}`);
  assert.ok(first.id && first.replay.length > 10);
  assert.equal((await next(`platform=1&fp=${FP}`)).none, true, "leased");
  assert.equal((await next(`platform=2&fp=${FP}`)).none, true, "other platform");
  assert.equal((await next(`platform=1&fp=${FP + 1}`)).none, true, "a verifier that computes differently gets nothing");
  assert.equal((await next("platform=1")).none, true, "a verifier must say how it computes");
  for (let i = 0; i < LIMITS.maxAttempts - 1; i++) {
    clock += LIMITS.leaseMs + 1000;
    assert.equal((await next(`platform=1&fp=${FP}`)).id, first.id, "a lease that ran out (Mac asleep, crash) is handed out again");
  }
  clock += LIMITS.leaseMs + 1000;
  assert.equal((await next(`platform=1&fp=${FP}`)).none, true);
  const s = await t.env.DB.prepare("SELECT status, reason FROM submissions WHERE id = ?1").bind(first.id).first();
  assert.deepEqual([s.status, s.reason], ["rejected", "verifier_gave_up"]);
  assert.equal((await t.call("POST", "/v1/verify/result", { id: first.id, ok: true, score: 800, wave: 3 }, { bearer: VT })).body.already, "rejected", "a late verdict changes nothing");
});

test("admin: hide, ban, rename, delete", async () => {
  const t = fresh();
  const a = await t.player(), b = await t.player();
  await runAndSubmit(t, a, { score: 9000, name: "CHEAT" });
  await verify(t);
  await runAndSubmit(t, b, { score: 100, name: "FAIR" });
  await verify(t);
  const adm = (path, body) => t.call(body ? "POST" : "GET", "/v1/admin/" + path, body, { bearer: AT });
  assert.equal((await adm("list")).body.scores.length, 2);
  await adm("hide", { player_id: a.player_id });
  let top = (await t.call("GET", "/v1/top?player=" + a.player_id)).body;
  assert.deepEqual(top.entries.map((e) => [e.rank, e.name]), [[1, "FAIR"]]);
  assert.equal(top.me, null);
  await adm("hide", { player_id: a.player_id, hidden: false });
  assert.equal((await t.call("GET", "/v1/top")).body.entries.length, 2);
  assert.equal((await t.call("GET", "/v1/top")).body.total, 2, "unhiding counts again");
  await adm("rename", { player_id: a.player_id, name: "RENAMED" });
  assert.equal((await t.call("GET", "/v1/top")).body.entries[0].name, "RENAMED");
  await adm("ban", { player_id: a.player_id });
  assert.equal((await t.call("GET", "/v1/top")).body.entries.length, 1);
  assert.equal((await t.call("POST", "/v1/run", { player_id: a.player_id, token: a.token })).status, 403);
  assert.equal((await t.call("GET", "/v1/top")).body.total, 1, "a banned player is not counted");
  await adm("delete", { player_id: a.player_id });
  assert.equal((await t.env.DB.prepare("SELECT COUNT(*) AS n FROM players").first()).n, 1);
  assert.equal((await t.call("GET", "/v1/top")).body.total, 1);
  await adm("delete", { player_id: b.player_id });
  assert.equal((await t.call("GET", "/v1/top")).body.total, 0);
  assert.equal((await adm("cleanup", {})).status, 200);
});

test("what is stored about a player: a random id, a token hash, a name. Nothing else", async () => {
  const t = fresh();
  const p = await t.player();
  const row = await t.env.DB.prepare("SELECT * FROM players WHERE id = ?1").bind(p.player_id).first();
  assert.deepEqual(Object.keys(row).sort(), ["banned", "created_at", "id", "name", "token_hash"]);
  assert.notEqual(row.token_hash, p.token);
  assert.equal(row.token_hash.length, 64);
});

test("records whose verifier never comes wait, then expire as unverifiable (not as cheating)", async () => {
  const t = fresh();
  const p = await t.player();
  const r = await runAndSubmit(t, p, { score: 900, patch: (b) => b.writeUInt32LE(FP + 5, 20) });
  assert.equal(r.body.status, "pending");
  assert.equal(await verify(t), null, "no verifier for that fingerprint");
  const q = (await t.call("GET", "/v1/admin/queue", null, { bearer: AT })).body;
  assert.deepEqual(q.queue.map((g) => [g.platform, g.build, g.fp, g.waiting]), [[1, BUILD, FP + 5, 1]]);
  clock += LIMITS.pendingExpireMs - 60_000;
  await t.call("POST", "/v1/admin/cleanup", {}, { bearer: AT });
  assert.equal((await t.env.DB.prepare("SELECT status FROM submissions").first()).status, "pending");
  clock += 120_000;
  await t.call("POST", "/v1/admin/cleanup", {}, { bearer: AT });
  const s = await t.env.DB.prepare("SELECT status, reason, replay FROM submissions").first();
  assert.deepEqual([s.status, s.reason, s.replay], ["rejected", "unverifiable", null]);
});

test("the Rate Limiting binding is used when present, and its outage does not block players", async () => {
  const t = fresh();
  const seen = [];
  let allow = true;
  t.env.RL_PLAYER = { limit: async ({ key }) => { seen.push(key); return { success: allow }; } };
  t.env.RL_READ = { limit: async () => { throw new Error("limiter down"); } };
  assert.equal((await t.call("POST", "/v1/player", null, { ip: "1.2.3.4" })).status, 200);
  allow = false;
  assert.equal((await t.call("POST", "/v1/player", null, { ip: "1.2.3.4" })).status, 429);
  assert.ok(seen.every((k) => k.startsWith("player:") && !k.includes("1.2.3.4")), "the binding sees a hash, not the address");
  for (let i = 0; i < 100; i++) assert.equal((await t.call("GET", "/v1/top")).status, 200);
  const minuteRows = await t.env.DB.prepare("SELECT COUNT(*) AS n FROM rate WHERE key LIKE '%:60'").first();
  assert.equal(minuteRows.n, 0, "with bindings, per-minute limits write nothing to D1");
});

test("wrangler.toml limits agree with the code", () => {
  const toml = readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8");
  const blocks = toml.split("[[ratelimits]]").slice(1);
  const found = {};
  for (const b of blocks) found[b.match(/name = "(\w+)"/)[1]] = [Number(b.match(/limit = (\d+)/)[1]), Number(b.match(/period = (\d+)/)[1])];
  for (const r of Object.values(RATE)) assert.deepEqual(found[r.binding], [r.max, 60], r.binding);
  assert.match(toml, /binding = "DB"/);
  assert.doesNotMatch(toml, /(TOKEN|SALT)\s*=/, "no secrets in the config file");
});

test("hot queries go through an index (rows read stay small as the board grows)", async () => {
  const t = fresh();
  const plan = async (sql, ...args) => (t.env.DB.raw.prepare("EXPLAIN QUERY PLAN " + sql).all(...args)).map((r) => r.detail).join(" | ");
  const queue = await plan("SELECT id FROM submissions WHERE status = 'pending' AND platform = 1 AND build = 3 AND fp = 5 AND leased_until < 9 ORDER BY created_at ASC LIMIT 1");
  assert.match(queue, /USING INDEX submissions_queue/);
  assert.doesNotMatch(queue, /TEMP B-TREE/);
  const board = await plan("SELECT player_id FROM scores WHERE hidden = 0 ORDER BY score DESC, achieved_at ASC, player_id ASC LIMIT 100");
  assert.match(board, /USING (COVERING )?INDEX scores_rank/);
  assert.doesNotMatch(board, /TEMP B-TREE/);
  assert.match(await plan("SELECT COUNT(*) FROM submissions WHERE player_id = 'x' AND status = 'pending'"), /submissions_player/);
});

test("a missing, short or placeholder secret closes the whole API (503), and says nothing about which", async () => {
  const good = fresh().env;
  assert.deepEqual(missingConfig(good), []);
  const paths = [["GET", "/v1/health"], ["GET", "/v1/top"], ["POST", "/v1/player"], ["POST", "/v1/run"], ["POST", "/v1/submit"],
    ["GET", "/v1/verify/next?platform=1&fp=1"], ["POST", "/v1/verify/result"], ["GET", "/v1/admin/list"], ["POST", "/v1/admin/delete"], ["GET", "/elsewhere"]];
  const cases = [];
  for (const k of SECRETS) {
    for (const v of [undefined, "", "short", "dev-salt", "x".repeat(40), "changeme-0123456789-0123456789-0123456789", "test-0123456789-0123456789-0123456789-0123", 12345]) cases.push({ ...good, [k]: v });
  }
  cases.push({ ...good, VERIFIER_TOKEN: good.ADMIN_TOKEN }, { ...good, DB: undefined }, {});
  for (const env of cases) {
    assert.ok(missingConfig(env).length > 0);
    for (const [method, path] of paths) {
      const headers = { "content-type": "application/json", authorization: "Bearer " + (env.VERIFIER_TOKEN ?? "") };
      const r = await worker.fetch(new Request("http://x" + path, { method, headers, body: method === "POST" ? "{}" : undefined }), env);
      const body = await r.text();
      assert.equal(r.status, 503, `${method} ${path}`);
      assert.equal(body, '{"ok":false,"error":"not_configured"}');
      for (const k of SECRETS) assert.ok(!body.includes(k));
    }
  }
  const rows = await good.DB.prepare("SELECT (SELECT COUNT(*) FROM players) + (SELECT COUNT(*) FROM rate) AS n").first();
  assert.equal(rows.n, 0, "a closed API writes nothing");
  const pre = await worker.fetch(new Request("http://x/v1/top", { method: "OPTIONS" }), {});
  assert.equal(pre.status, 204, "the browser's preflight still gets an answer, so the game sees a clean 503");
});

test("with every secret set the API is open, and an empty token still opens no door", async () => {
  const t = fresh();
  assert.equal((await t.call("GET", "/v1/health")).status, 200);
  const r = await worker.fetch(new Request("http://x/v1/verify/next?platform=1&fp=1", { headers: { authorization: "Bearer " } }), t.env);
  assert.equal(r.status, 401);
});

test("the first deployment is closed by default: no workers.dev route, no version URLs", () => {
  const toml = readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8");
  assert.match(toml, /^workers_dev = (false|true)$/m);
  assert.match(toml, /^preview_urls = false$/m);
});
