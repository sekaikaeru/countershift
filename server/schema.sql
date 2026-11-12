-- COUNTERSHIFT ranking: D1 (SQLite) schema. Apply once to an empty database:
--   wrangler d1 execute countershift-ranking --remote --file=schema.sql
-- No personal data: a player is a random id, a hashed random token and a display name.
-- (Not yet applied anywhere remote. Once it is, change it only with new, additive migrations.)

CREATE TABLE IF NOT EXISTS players (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  banned INTEGER NOT NULL DEFAULT 0
);

-- A run ticket: the server picks the seed, and knows when the run really started.
CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  player_id TEXT NOT NULL,
  seed INTEGER NOT NULL,
  issued_at INTEGER NOT NULL,
  started_at INTEGER,
  used INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS runs_issued ON runs (issued_at);

-- A submitted run. It is only a claim until a verifier has replayed it.
-- platform/build/fp say which game build can replay it (scripts/replay.gd).
CREATE TABLE IF NOT EXISTS submissions (
  id TEXT PRIMARY KEY,
  player_id TEXT NOT NULL,
  run_id TEXT NOT NULL UNIQUE,
  score INTEGER NOT NULL,
  wave INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL,
  frames INTEGER NOT NULL,
  platform INTEGER NOT NULL,
  build INTEGER NOT NULL,
  fp INTEGER NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'verified', 'rejected')),
  reason TEXT NOT NULL DEFAULT '',
  replay TEXT,
  created_at INTEGER NOT NULL,
  leased_until INTEGER NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0,
  verified_at INTEGER
);
CREATE INDEX IF NOT EXISTS submissions_queue ON submissions (status, platform, build, fp, created_at);
CREATE INDEX IF NOT EXISTS submissions_player ON submissions (player_id, status);

-- The public board: one row per player, the best verified run.
CREATE TABLE IF NOT EXISTS scores (
  player_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  score INTEGER NOT NULL,
  wave INTEGER NOT NULL,
  achieved_at INTEGER NOT NULL,
  submission_id TEXT NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS scores_rank ON scores (hidden, score DESC, achieved_at ASC, player_id ASC);

-- Counters kept by triggers, so the board total is one row read instead of a scan.
CREATE TABLE IF NOT EXISTS meta (
  k TEXT PRIMARY KEY,
  v INTEGER NOT NULL
);
INSERT OR IGNORE INTO meta (k, v) VALUES ('visible', 0);

CREATE TRIGGER IF NOT EXISTS scores_visible_insert AFTER INSERT ON scores WHEN NEW.hidden = 0
BEGIN
  UPDATE meta SET v = v + 1 WHERE k = 'visible';
END;

CREATE TRIGGER IF NOT EXISTS scores_visible_delete AFTER DELETE ON scores WHEN OLD.hidden = 0
BEGIN
  UPDATE meta SET v = v - 1 WHERE k = 'visible';
END;

CREATE TRIGGER IF NOT EXISTS scores_visible_change AFTER UPDATE OF hidden ON scores WHEN OLD.hidden <> NEW.hidden
BEGIN
  UPDATE meta SET v = v + (CASE WHEN NEW.hidden = 0 THEN 1 ELSE -1 END) WHERE k = 'visible';
END;

-- Request counters where no Rate Limiting binding is configured, and the daily caps.
-- The key is a salted hash, never a raw address.
CREATE TABLE IF NOT EXISTS rate (
  key TEXT NOT NULL,
  win INTEGER NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (key, win)
);
