// COUNTERSHIFT ranking API: all the logic. The Workers entry point is worker.js.
// A score is never trusted: the client sends the full input replay of a run whose seed the
// server chose, and the run reaches the public board only after a verifier has replayed it
// in a game build that computes the game identically (same platform, build and fingerprint)
// and got the same score.
//
// Written for the Workers Free plan: 10 ms CPU per request, D1 5 M rows read and 100 k rows
// written per day. So the Worker never decompresses a whole replay (only its header), minute
// rate limits use the Rate Limiting binding when it is configured (no D1 writes), the board
// total is a counter kept by triggers, and the verifier queue is read through one index.

export const BUILD = 3;                 // must match scripts/replay.gd BUILD
export const FORMAT = 2;                // replay format, scripts/replay.gd FORMAT
export const HEADER = 28;
export const LIMITS = {
  nameMax: 12,
  ticketTtlMs: 30 * 60 * 1000,          // a ticket must be started within 30 minutes
  pauseAllowanceMs: 15 * 60 * 1000,     // wall clock may exceed play time by this much (pauses)
  earlyToleranceMs: 3000,               // wall clock may be this much shorter than play time
  maxReplayB64: 1_900_000,              // D1 row limit is 2 MB
  maxFrames: 1_200_000,
  maxBody: 2_000_000,
  leaseMs: 120_000,                     // a verifier holds a job this long
  maxAttempts: 3,                       // leases without an answer before a job is given up
  pendingExpireMs: 7 * 86_400_000,      // never verified (no verifier for that build): expires
  topCacheMs: 20_000,                   // the public top 100 is cached per isolate this long
};

// Per-minute limits. With a Rate Limiting binding of the same name (wrangler.toml) the binding
// counts (approximate, per Cloudflare location, no D1 writes); without one, D1 counts exactly.
// The numbers here must equal the ones in wrangler.toml (a test checks).
export const RATE = {
  player: { binding: "RL_PLAYER", max: 3 },    // new anonymous players, per address
  play: { binding: "RL_PLAY", max: 20 },       // tickets, starts, name changes, per player
  submit: { binding: "RL_SUBMIT", max: 6 },    // submissions, per player
  read: { binding: "RL_READ", max: 60 },       // board per address, submission status per player
};
// Daily caps, always counted in D1 (one written row per request, only on these two routes).
export const DAILY = { player: 20, submit: 200 };

// Secrets the API cannot run without. If one is missing, too short or a known placeholder, the
// whole API answers 503 (the game then plays offline): it never runs half-configured.
export const SECRETS = ["RATE_SALT", "VERIFIER_TOKEN", "ADMIN_TOKEN"];
export const SECRET_MIN = 32;
const PLACEHOLDER = /^(dev|test|example|changeme|change-me|replace|placeholder|salt|secret|todo|xxx)/i;

/** Names of what is missing or unusable in the configuration (empty = ready). */
export function missingConfig(env) {
  const bad = [];
  if (!env?.DB || typeof env.DB.prepare !== "function") bad.push("DB");
  for (const k of SECRETS) {
    const v = env?.[k];
    if (typeof v !== "string" || v.length < SECRET_MIN || PLACEHOLDER.test(v) || /^(.)\1*$/.test(v)) bad.push(k);
  }
  const vals = SECRETS.map((k) => env?.[k]).filter((v) => typeof v === "string");
  if (new Set(vals).size !== vals.length) bad.push("SECRETS_NOT_DISTINCT");
  return bad;
}

const PLATFORMS = { 1: "web", 2: "macos-arm64", 3: "macos-x64", 4: "windows-x64", 5: "linux-x64" };
const BANNED = ["admin", "official", "moderator", "countershift", "運営", "公式", "管理者",
  "fuck", "shit", "bitch", "nigg", "fag", "cunt", "rape", "hitler", "nazi",
  "死ね", "殺す", "ころす", "しね", "レイプ", "ちんこ", "まんこ", "うんこ"];

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "content-type, authorization",
  "access-control-max-age": "86400",
  "x-content-type-options": "nosniff",
};
const json = (data, status = 200) => new Response(JSON.stringify(data), {
  status,
  headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...CORS },
});
const fail = (status, error, extra = {}) => json({ ok: false, error, ...extra }, status);

async function sha256(text) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomHex(bytes) {
  const a = new Uint8Array(bytes);
  crypto.getRandomValues(a);
  return [...a].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sameText(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/** Display name: 1-12 characters of ASCII letters/digits, kana, kanji and a few marks. */
export function cleanName(raw) {
  if (typeof raw !== "string" || raw.length > 64) return null;
  const s = raw.normalize("NFKC").replace(/\s+/g, " ").trim();
  const len = [...s].length;
  if (len < 1 || len > LIMITS.nameMax) return null;
  if (!/^[A-Za-z0-9\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}ー・ _.\-]+$/u.test(s)) return null;
  const low = s.toLowerCase().replace(/[ _.\-・]/g, "");
  if (low.length === 0) return null;
  for (const w of BANNED) if (low.includes(w)) return null;
  return s;
}

async function readBody(request) {
  const declared = Number(request.headers.get("content-length") || "0");
  if (declared > LIMITS.maxBody) return null;
  const text = await request.text();
  if (text.length > LIMITS.maxBody) return null;
  try {
    const v = JSON.parse(text);
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- rate limits

async function addressKey(request, env) {
  const ip = request.headers.get("cf-connecting-ip") || "local";
  const day = Math.floor(Date.now() / 86_400_000);
  return (await sha256(`${env.RATE_SALT}|${day}|${ip}`)).slice(0, 24);
}

/** D1 fixed-window counter. Returns true while the caller is within the limit. */
async function count(env, key, windowSec, max) {
  const win = Math.floor(Date.now() / 1000 / windowSec);
  const row = await env.DB.prepare(
    "INSERT INTO rate (key, win, count) VALUES (?1, ?2, 1) ON CONFLICT (key, win) DO UPDATE SET count = count + 1 RETURNING count",
  ).bind(`${key}:${windowSec}`, win).first();
  return (row?.count ?? 1) <= max;
}

/** Per-minute limit: the Rate Limiting binding if configured, else D1. */
async function minute(env, kind, key) {
  const r = RATE[kind];
  const rl = env[r.binding];
  if (rl && typeof rl.limit === "function") {
    try {
      return (await rl.limit({ key: `${kind}:${key}` })).success;
    } catch {
      return true;   // a limiter outage must not take the game's ranking down
    }
  }
  return count(env, `${kind}:${key}`, 60, r.max);
}

// ---------------------------------------------------------------- auth

async function auth(env, body) {
  if (typeof body.player_id !== "string" || typeof body.token !== "string") return null;
  if (body.player_id.length > 64 || body.token.length > 128) return null;
  const p = await env.DB.prepare("SELECT id, token_hash, name, banned FROM players WHERE id = ?1").bind(body.player_id).first();
  if (!p || !sameText(p.token_hash, await sha256(body.token))) return null;
  return p;
}

function bearer(request, secret) {
  if (typeof secret !== "string" || secret.length < SECRET_MIN) return false;
  const h = request.headers.get("authorization") || "";
  return h.startsWith("Bearer ") && sameText(h.slice(7), secret);
}

// ---------------------------------------------------------------- replay header

/**
 * Decompresses only as much of the replay as the header needs. The Worker never inflates a
 * whole replay (CPU limit, zip bombs); the verifier does that, with its own size cap.
 */
export async function readReplayHeader(b64) {
  const head = b64.slice(0, 8192);
  let bin;
  try {
    bin = atob(head.length % 4 === 0 ? head : head.slice(0, head.length - (head.length % 4)));
  } catch {
    return null;
  }
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const ds = new DecompressionStream("gzip");
  const writer = ds.writable.getWriter();
  const reader = ds.readable.getReader();
  writer.write(bytes).catch(() => {});
  const out = new Uint8Array(HEADER);
  let got = 0;
  try {
    while (got < HEADER) {
      let timer;
      const { done, value } = await Promise.race([reader.read(), new Promise((r) => { timer = setTimeout(() => r({ done: true }), 1000); })]);
      clearTimeout(timer);
      if (done || !value) break;
      const take = Math.min(value.length, HEADER - got);
      out.set(value.subarray(0, take), got);
      got += take;
    }
  } catch {
    got = 0;
  }
  reader.cancel().catch(() => {});
  writer.abort().catch(() => {});
  return got === HEADER ? out : null;
}

/** Checks a replay header. Layout: see scripts/replay.gd. */
export function inspectHeader(raw) {
  if (!raw || raw.length < HEADER) return { error: "replay_unreadable" };
  const v = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  if (v.getUint32(0, true) !== 0x31525343) return { error: "replay_magic" };
  if (v.getUint8(4) !== FORMAT) return { error: "replay_format" };
  const flags = v.getUint8(5);
  const platform = v.getUint8(6);
  const seed = v.getUint32(8, true);
  const frames = v.getUint32(12, true);
  const build = v.getUint16(16, true);
  const fp = v.getUint32(20, true);
  const durationMs = v.getUint32(24, true);
  if (flags > 1 || !PLATFORMS[platform] || v.getUint8(7) !== 0 || v.getUint16(18, true) !== 0) return { error: "replay_header" };
  if (frames < 1 || frames > LIMITS.maxFrames) return { error: "replay_length" };
  // the game clamps a frame to 50 ms of play: so many frames need at least this much play time,
  // and more than 400 frames per second of play is not a real display
  if (durationMs > frames * 50 + 1) return { error: "replay_duration" };
  if (frames > (durationMs / 1000) * 400 + 600) return { error: "replay_frame_rate" };
  return { seed, frames, platform, build, fp, durationMs, tutorial: (flags & 1) === 1 };
}

// ---------------------------------------------------------------- ranking

let topCache = null;     // { db, at, rows, total } per isolate

async function total(env) {
  return (await env.DB.prepare("SELECT v FROM meta WHERE k = 'visible'").first())?.v ?? 0;
}

async function rankOf(env, playerId) {
  const me = await env.DB.prepare("SELECT name, score, wave, achieved_at, hidden FROM scores WHERE player_id = ?1").bind(playerId).first();
  if (!me || me.hidden) return null;
  const above = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM scores WHERE hidden = 0 AND (score > ?1 OR (score = ?1 AND (achieved_at < ?2 OR (achieved_at = ?2 AND player_id < ?3))))",
  ).bind(me.score, me.achieved_at, playerId).first();
  return { rank: (above?.n ?? 0) + 1, name: me.name, score: me.score, wave: me.wave, at: me.achieved_at };
}

/** Where a score would stand right now (the provisional rank of an unverified run). */
async function rankForScore(env, score) {
  const above = await env.DB.prepare("SELECT COUNT(*) AS n FROM scores WHERE hidden = 0 AND score >= ?1").bind(score).first();
  return (above?.n ?? 0) + 1;
}

// ---------------------------------------------------------------- handlers

async function createPlayer(request, env) {
  const key = await addressKey(request, env);
  if (!(await minute(env, "player", key)) || !(await count(env, "player-day:" + key, 86400, DAILY.player))) return fail(429, "rate_limited");
  const id = crypto.randomUUID();
  const token = randomHex(32);
  await env.DB.prepare("INSERT INTO players (id, token_hash, name, created_at) VALUES (?1, ?2, '', ?3)").bind(id, await sha256(token), Date.now()).run();
  return json({ ok: true, player_id: id, token });
}

async function createRun(request, env, body) {
  const p = await auth(env, body);
  if (!p) return fail(401, "unauthorized");
  if (p.banned) return fail(403, "banned");
  if (!(await minute(env, "play", p.id))) return fail(429, "rate_limited");
  const id = crypto.randomUUID();
  const s = new Uint32Array(1);
  crypto.getRandomValues(s);
  const seed = (s[0] % 2147483646) + 1;
  await env.DB.prepare("INSERT INTO runs (id, player_id, seed, issued_at) VALUES (?1, ?2, ?3, ?4)").bind(id, p.id, seed, Date.now()).run();
  return json({ ok: true, run_id: id, seed, build: BUILD });
}

async function startRun(request, env, body) {
  const p = await auth(env, body);
  if (!p) return fail(401, "unauthorized");
  if (typeof body.run_id !== "string") return fail(400, "bad_request");
  if (!(await minute(env, "play", p.id))) return fail(429, "rate_limited");
  const now = Date.now();
  const r = await env.DB.prepare(
    "UPDATE runs SET started_at = ?1 WHERE id = ?2 AND player_id = ?3 AND started_at IS NULL AND used = 0 AND issued_at > ?4",
  ).bind(now, body.run_id, p.id, now - LIMITS.ticketTtlMs).run();
  if ((r.meta?.changes ?? 0) !== 1) return fail(409, "run_not_startable");
  return json({ ok: true });
}

async function setName(request, env, body) {
  const p = await auth(env, body);
  if (!p) return fail(401, "unauthorized");
  if (p.banned) return fail(403, "banned");
  if (!(await minute(env, "play", p.id))) return fail(429, "rate_limited");
  const name = cleanName(body.name);
  if (!name) return fail(400, "bad_name");
  await env.DB.batch([
    env.DB.prepare("UPDATE players SET name = ?1 WHERE id = ?2").bind(name, p.id),
    env.DB.prepare("UPDATE scores SET name = ?1 WHERE player_id = ?2").bind(name, p.id),
  ]);
  topCache = null;
  return json({ ok: true, name });
}

async function submit(request, env, body) {
  const p = await auth(env, body);
  if (!p) return fail(401, "unauthorized");
  if (p.banned) return fail(403, "banned");
  if (!(await minute(env, "submit", p.id)) || !(await count(env, "submit-day:" + p.id, 86400, DAILY.submit))) return fail(429, "rate_limited");
  const name = cleanName(body.name);
  if (!name) return fail(400, "bad_name");
  const score = body.score, wave = body.wave;
  if (!Number.isSafeInteger(score) || !Number.isSafeInteger(wave) || score < 1 || score > 2_000_000_000 || wave < 1 || wave > 100_000) return fail(400, "bad_score");
  if (typeof body.run_id !== "string" || typeof body.replay !== "string") return fail(400, "bad_request");
  if (body.replay.length > LIMITS.maxReplayB64) return fail(413, "replay_too_large");
  // only the start is checked here (a full-length pattern test costs ~10 ms of CPU on a long
  // replay); the verifier rejects anything that does not decode. It is never shown as HTML.
  if (body.replay.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(body.replay.slice(0, 8192))) return fail(400, "replay_unreadable");

  const now = Date.now();
  const run = await env.DB.prepare("SELECT id, seed, started_at, used FROM runs WHERE id = ?1 AND player_id = ?2").bind(body.run_id, p.id).first();
  if (!run) return fail(404, "run_unknown");
  if (run.used) return fail(409, "run_used");
  if (!run.started_at) return fail(409, "run_not_started");

  const info = inspectHeader(await readReplayHeader(body.replay));
  if (info.error) return fail(400, info.error);
  if (info.build !== BUILD) return fail(409, "build_mismatch", { build: BUILD });
  if (info.seed !== run.seed) return fail(400, "seed_mismatch");
  const wall = now - run.started_at;
  if (wall < info.durationMs - LIMITS.earlyToleranceMs) return fail(400, "too_fast");
  if (wall > info.durationMs + LIMITS.pauseAllowanceMs) return fail(400, "too_slow");
  const sec = info.durationMs / 1000;
  if (score > 8000 * sec + 20000 || wave > sec / 2 + 3) return fail(400, "implausible");

  // one submission per ticket, whatever happens next
  const used = await env.DB.prepare("UPDATE runs SET used = 1 WHERE id = ?1 AND used = 0").bind(run.id).run();
  if ((used.meta?.changes ?? 0) !== 1) return fail(409, "run_used");
  if (p.name !== name) await env.DB.prepare("UPDATE players SET name = ?1 WHERE id = ?2").bind(name, p.id).run();

  const best = await env.DB.prepare("SELECT score FROM scores WHERE player_id = ?1").bind(p.id).first();
  if (best && best.score >= score) {
    if (p.name !== name) {
      await env.DB.prepare("UPDATE scores SET name = ?1 WHERE player_id = ?2").bind(name, p.id).run();
      topCache = null;
    }
    return json({ ok: true, status: "not_best", me: await rankOf(env, p.id), total: await total(env) });
  }
  const id = crypto.randomUUID();
  await env.DB.prepare(
    "INSERT INTO submissions (id, player_id, run_id, score, wave, duration_ms, frames, platform, build, fp, status, replay, created_at) " +
    "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'pending', ?11, ?12)",
  ).bind(id, p.id, run.id, score, wave, info.durationMs, info.frames, info.platform, info.build, info.fp, body.replay, now).run();
  return json({ ok: true, status: "pending", submission_id: id, provisional_rank: await rankForScore(env, score), total: await total(env) });
}

async function submissionStatus(request, env, body) {
  const p = await auth(env, body);
  if (!p) return fail(401, "unauthorized");
  if (!(await minute(env, "read", "p:" + p.id))) return fail(429, "rate_limited");
  const s = await env.DB.prepare("SELECT status, reason, score, wave FROM submissions WHERE id = ?1 AND player_id = ?2").bind(String(body.submission_id || ""), p.id).first();
  if (!s) return fail(404, "submission_unknown");
  const out = { ok: true, status: s.status, reason: s.reason, score: s.score, wave: s.wave };
  if (s.status !== "pending") { out.me = await rankOf(env, p.id); out.total = await total(env); }
  return json(out);
}

async function top(request, env, url) {
  if (!(await minute(env, "read", "a:" + (await addressKey(request, env))))) return fail(429, "rate_limited");
  const limit = Math.max(1, Math.min(100, Number(url.searchParams.get("limit") || "100") | 0));
  const now = Date.now();
  if (!topCache || topCache.db !== env.DB || now - topCache.at > LIMITS.topCacheMs || now < topCache.at) {
    const rows = await env.DB.prepare(
      "SELECT player_id, name, score, wave, achieved_at FROM scores WHERE hidden = 0 ORDER BY score DESC, achieved_at ASC, player_id ASC LIMIT 100",
    ).all();
    topCache = { db: env.DB, at: now, rows: rows.results, total: await total(env) };
  }
  const player = url.searchParams.get("player") || "";
  const entries = topCache.rows.slice(0, limit).map((r, i) => ({ rank: i + 1, name: r.name, score: r.score, wave: r.wave, at: r.achieved_at, me: r.player_id === player }));
  const out = { ok: true, entries, total: topCache.total, now };
  if (player && player.length <= 64) {
    out.me = await rankOf(env, player);
    const pend = await env.DB.prepare("SELECT COUNT(*) AS n FROM submissions WHERE player_id = ?1 AND status = 'pending'").bind(player).first();
    out.pending = pend?.n ?? 0;
  }
  return json(out);
}

// ---- verifier (trusted, holds VERIFIER_TOKEN)

async function verifyNext(request, env, url) {
  if (!bearer(request, env.VERIFIER_TOKEN)) return fail(401, "unauthorized");
  const platform = Number(url.searchParams.get("platform") || "0");
  const fp = Number(url.searchParams.get("fp") ?? "-1");
  if (!Number.isInteger(platform) || !Number.isInteger(fp) || fp < 0) return json({ ok: true, none: true, build: BUILD });
  const now = Date.now();
  // the oldest free job for exactly this platform, build and fingerprint (one index range)
  for (let tries = 0; tries < 5; tries++) {
    const job = await env.DB.prepare(
      "SELECT id, replay, attempts FROM submissions WHERE status = 'pending' AND platform = ?1 AND build = ?2 AND fp = ?3 AND leased_until < ?4 ORDER BY created_at ASC LIMIT 1",
    ).bind(platform, BUILD, fp, now).first();
    if (!job) return json({ ok: true, none: true, build: BUILD });
    if (job.attempts >= LIMITS.maxAttempts) {
      // leased again and again without an answer: this replay stops verifiers (crash, hang)
      await env.DB.prepare("UPDATE submissions SET status = 'rejected', reason = 'verifier_gave_up', replay = NULL, verified_at = ?1 WHERE id = ?2 AND status = 'pending'").bind(now, job.id).run();
      continue;
    }
    const got = await env.DB.prepare("UPDATE submissions SET leased_until = ?1, attempts = attempts + 1 WHERE id = ?2 AND status = 'pending' AND leased_until < ?3")
      .bind(now + LIMITS.leaseMs, job.id, now).run();
    if ((got.meta?.changes ?? 0) === 1) return json({ ok: true, id: job.id, replay: job.replay, build: BUILD });
  }
  return json({ ok: true, none: true, build: BUILD });
}

async function verifyResult(request, env, body) {
  if (!bearer(request, env.VERIFIER_TOKEN)) return fail(401, "unauthorized");
  const s = await env.DB.prepare("SELECT id, player_id, score, wave, duration_ms, status, created_at FROM submissions WHERE id = ?1").bind(String(body.id || "")).first();
  if (!s) return fail(404, "submission_unknown");
  if (s.status !== "pending") return json({ ok: true, already: s.status });
  const now = Date.now();
  let reason = "";
  if (body.ok !== true) reason = "replay_invalid:" + String(body.reason || "").slice(0, 40);
  else if (body.score !== s.score || body.wave !== s.wave) reason = "score_mismatch";
  else if (body.time_ms !== s.duration_ms) reason = "duration_mismatch";
  if (reason) {
    await env.DB.prepare("UPDATE submissions SET status = 'rejected', reason = ?1, replay = NULL, verified_at = ?2 WHERE id = ?3 AND status = 'pending'").bind(reason, now, s.id).run();
    return json({ ok: true, status: "rejected", reason });
  }
  const p = await env.DB.prepare("SELECT name, banned FROM players WHERE id = ?1").bind(s.player_id).first();
  const prev = await env.DB.prepare("SELECT score, submission_id FROM scores WHERE player_id = ?1").bind(s.player_id).first();
  const better = !prev || s.score > prev.score;
  const batch = [
    env.DB.prepare("UPDATE submissions SET status = 'verified', verified_at = ?1, replay = CASE WHEN ?2 = 1 THEN replay ELSE NULL END WHERE id = ?3 AND status = 'pending'").bind(now, better ? 1 : 0, s.id),
  ];
  if (better && p && !p.banned) {
    batch.push(env.DB.prepare(
      "INSERT INTO scores (player_id, name, score, wave, achieved_at, submission_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6) " +
      "ON CONFLICT (player_id) DO UPDATE SET name = excluded.name, score = excluded.score, wave = excluded.wave, achieved_at = excluded.achieved_at, submission_id = excluded.submission_id WHERE excluded.score > scores.score",
    ).bind(s.player_id, p.name || "PLAYER", s.score, s.wave, s.created_at, s.id));
    if (prev) batch.push(env.DB.prepare("UPDATE submissions SET replay = NULL WHERE id = ?1").bind(prev.submission_id));
  }
  await env.DB.batch(batch);
  topCache = null;
  return json({ ok: true, status: "verified" });
}

// ---- admin (holds ADMIN_TOKEN)

async function admin(request, env, url, body) {
  if (!bearer(request, env.ADMIN_TOKEN)) return fail(401, "unauthorized");
  const action = url.pathname.slice("/v1/admin/".length);
  const pid = String(body?.player_id || "");
  topCache = null;
  switch (action) {
    case "list": {
      const status = url.searchParams.get("status");
      if (status) {
        const r = await env.DB.prepare("SELECT id, player_id, score, wave, duration_ms, platform, build, fp, status, reason, attempts, created_at FROM submissions WHERE status = ?1 ORDER BY created_at DESC LIMIT 200").bind(status).all();
        return json({ ok: true, submissions: r.results });
      }
      const r = await env.DB.prepare("SELECT player_id, name, score, wave, achieved_at, hidden FROM scores ORDER BY score DESC LIMIT 500").all();
      return json({ ok: true, scores: r.results });
    }
    case "queue": {
      // what is waiting, by the verifier it needs; a group nobody verifies points at a missing verifier
      const r = await env.DB.prepare(
        "SELECT platform, build, fp, COUNT(*) AS waiting, MIN(created_at) AS oldest, MAX(attempts) AS max_attempts FROM submissions WHERE status = 'pending' GROUP BY platform, build, fp",
      ).all();
      return json({ ok: true, build: BUILD, queue: r.results, now: Date.now() });
    }
    case "hide":
      await env.DB.prepare("UPDATE scores SET hidden = ?1 WHERE player_id = ?2").bind(body.hidden === false ? 0 : 1, pid).run();
      return json({ ok: true });
    case "rename": {
      const name = cleanName(body.name);
      if (!name) return fail(400, "bad_name");
      await env.DB.batch([
        env.DB.prepare("UPDATE players SET name = ?1 WHERE id = ?2").bind(name, pid),
        env.DB.prepare("UPDATE scores SET name = ?1 WHERE player_id = ?2").bind(name, pid),
      ]);
      return json({ ok: true });
    }
    case "ban":
      await env.DB.batch([
        env.DB.prepare("UPDATE players SET banned = ?1 WHERE id = ?2").bind(body.banned === false ? 0 : 1, pid),
        env.DB.prepare("UPDATE scores SET hidden = ?1 WHERE player_id = ?2").bind(body.banned === false ? 0 : 1, pid),
      ]);
      return json({ ok: true });
    case "delete":
      await env.DB.batch([
        env.DB.prepare("DELETE FROM scores WHERE player_id = ?1").bind(pid),
        env.DB.prepare("DELETE FROM submissions WHERE player_id = ?1").bind(pid),
        env.DB.prepare("DELETE FROM runs WHERE player_id = ?1").bind(pid),
        env.DB.prepare("DELETE FROM players WHERE id = ?1").bind(pid),
      ]);
      return json({ ok: true });
    case "requeue":
      await env.DB.prepare("UPDATE submissions SET status = 'pending', reason = '', attempts = 0, leased_until = 0 WHERE id = ?1 AND replay IS NOT NULL").bind(String(body.id || "")).run();
      return json({ ok: true });
    case "cleanup": {
      const now = Date.now();
      const r = await env.DB.batch([
        env.DB.prepare("DELETE FROM rate WHERE win < ?1 AND key LIKE '%:60'").bind(Math.floor(now / 60_000) - 5),
        env.DB.prepare("DELETE FROM rate WHERE win < ?1 AND key LIKE '%:86400'").bind(Math.floor(now / 86_400_000) - 2),
        env.DB.prepare("DELETE FROM runs WHERE issued_at < ?1 AND id NOT IN (SELECT run_id FROM submissions WHERE status = 'pending')").bind(now - 3 * 86_400_000),
        env.DB.prepare("UPDATE submissions SET status = 'rejected', reason = 'unverifiable', replay = NULL, verified_at = ?1 WHERE status = 'pending' AND created_at < ?2").bind(now, now - LIMITS.pendingExpireMs),
        env.DB.prepare("DELETE FROM submissions WHERE status = 'rejected' AND created_at < ?1").bind(now - 30 * 86_400_000),
      ]);
      return json({ ok: true, changes: r.map((x) => x.meta?.changes ?? 0) });
    }
  }
  return fail(404, "not_found");
}

export async function handle(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const missing = missingConfig(env);
  if (missing.length) {
    console.error("not configured: " + missing.join(", "));      // names only, in the Worker's own log
    return fail(503, "not_configured");
  }
  if (!path.startsWith("/v1/")) return fail(404, "not_found");
  if (request.method === "GET") {
    if (path === "/v1/top") return top(request, env, url);
    if (path === "/v1/health") return json({ ok: true, build: BUILD });
    if (path === "/v1/verify/next") return verifyNext(request, env, url);
    if (path === "/v1/admin/list" || path === "/v1/admin/queue") return admin(request, env, url, null);
    return fail(404, "not_found");
  }
  if (request.method !== "POST") return fail(405, "method_not_allowed");
  if (path === "/v1/player") return createPlayer(request, env);
  const body = await readBody(request);
  if (!body) return fail(400, "bad_request");
  switch (path) {
    case "/v1/run": return createRun(request, env, body);
    case "/v1/run/start": return startRun(request, env, body);
    case "/v1/name": return setName(request, env, body);
    case "/v1/submit": return submit(request, env, body);
    case "/v1/submission": return submissionStatus(request, env, body);
    case "/v1/verify/result": return verifyResult(request, env, body);
  }
  if (path.startsWith("/v1/admin/")) return admin(request, env, url, body);
  return fail(404, "not_found");
}
