// The Cloudflare door (tools/cf.mjs) against a fake Cloudflare API: it must stop on anything
// that is not the pinned COUNTERSHIFT account, and must never hand other credentials to wrangler.
import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const CF = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "tools", "cf.mjs");
const ID = "0123456789abcdef0123456789abcd42", OTHER = "ffffffffffffffffffffffffffffff99";
const TOKEN = "test-token-not-a-real-one-000000000000";

import { spawn } from "node:child_process";
// the fake API runs in its own process: the tool is run with spawnSync, which blocks this one
const worldFile = join(mkdtempSync(join(tmpdir(), "cs-cfw-")), "world.json");
let world;
const save = () => writeFileSync(worldFile, JSON.stringify({ token: TOKEN, ...world }));
world = { tokenStatus: "active", accounts: [], workers: [], dbs: [] };
save();
const fake = spawn(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), "fake-cloudflare.mjs"), worldFile], { stdio: ["ignore", "pipe", "inherit"] });
const port = await new Promise((r) => fake.stdout.once("data", (d) => r(Number(String(d).trim()))));
test.after(() => fake.kill());

function setup({ mode = 0o600, id = ID, token = TOKEN } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "cs-cf-"));
  const envFile = join(dir, ".cf.env");
  writeFileSync(envFile, `CLOUDFLARE_API_TOKEN=${token}\nCLOUDFLARE_ACCOUNT_ID=${id}\n`);
  chmodSync(envFile, mode);
  const stub = join(dir, "wrangler-stub.sh");
  writeFileSync(stub, `#!/bin/bash\n{ echo "ARGS $@"; echo "TOKEN $CLOUDFLARE_API_TOKEN"; echo "ACCOUNT $CLOUDFLARE_ACCOUNT_ID"; echo "XDG $XDG_CONFIG_HOME"; echo "KEY [$CLOUDFLARE_API_KEY]"; echo "EMAIL [$CLOUDFLARE_EMAIL]"; echo "BASE [$CLOUDFLARE_API_BASE_URL]"; } > "${dir}/called.txt"\n`);
  chmodSync(stub, 0o755);
  world = { tokenStatus: "active", accounts: [{ id: ID, name: "Countershift Test" }], workers: [], dbs: [] };
  const run = (args, extra = {}) => {
    save();
    const r = spawnSync(process.execPath, [CF, ...args], { encoding: "utf8",
      env: { PATH: process.env.PATH, HOME: dir, CF_ENV_FILE: envFile, CF_PIN_FILE: join(dir, ".cf.pin"), CF_HOME_DIR: join(dir, "home"),
        CF_API_BASE: `http://127.0.0.1:${port}/client/v4`, CF_WRANGLER: stub,
        CLOUDFLARE_API_KEY: "global-key-of-another-project", CLOUDFLARE_EMAIL: "someone@example.invalid", CLOUDFLARE_API_BASE_URL: "http://elsewhere.invalid", ...extra } });
    return { code: r.status, out: r.stdout + r.stderr, called: existsSync(join(dir, "called.txt")) ? readFileSync(join(dir, "called.txt"), "utf8") : "" };
  };
  return { dir, run };
}

test("check shows the account without the id or the token, and changes nothing", () => {
  const t = setup();
  world.workers = ["countershift-ranking"]; world.dbs = ["countershift-ranking"];
  const r = t.run(["check"]);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /Countershift Test/);
  assert.match(r.out, /…cd42/);
  assert.ok(!r.out.includes(ID) && !r.out.includes(TOKEN), "no full id, no token in the output");
  assert.equal(r.called, "", "wrangler was not run");
});

test("it stops when the account is not the expected one", () => {
  let t = setup();
  world.accounts = [{ id: ID, name: "A" }, { id: OTHER, name: "B" }];
  assert.match(t.run(["check"]).out, /STOP: the token can see 2 accounts/);
  t = setup();
  world.accounts = [{ id: OTHER, name: "B" }];
  assert.match(t.run(["check"]).out, /STOP: the account the token can see is not/);
  t = setup();
  world.dbs = ["otherproject-prod"];
  const r = t.run(["check"]);
  assert.equal(r.code, 1);
  assert.match(r.out, /NOT the COUNTERSHIFT account/);
  t = setup();
  world.workers = ["blog"];
  assert.equal(t.run(["wrangler", "whoami"]).code, 1);
  t = setup();
  world.tokenStatus = "disabled";
  assert.match(t.run(["check"]).out, /not valid or not active/);
  t = setup({ token: "wrong-token-000000000000000000" });
  assert.equal(t.run(["check"]).code, 1);
});

test("it stops on a missing, open or broken credentials file", () => {
  assert.match(setup({ mode: 0o644 }).run(["check"]).out, /can be read by others/);
  assert.match(setup({ id: "not-an-id" }).run(["check"]).out, /CLOUDFLARE_ACCOUNT_ID is missing or malformed/);
  const t = setup();
  assert.match(t.run(["check"], { CF_ENV_FILE: join(t.dir, "nope") }).out, /is missing/);
});

test("nothing runs before the account is pinned; pinning needs the confirmation", () => {
  const t = setup();
  assert.match(t.run(["wrangler", "whoami"]).out, /not pinned yet/);
  assert.match(t.run(["pin"]).out, /CF_CONFIRM/);
  assert.equal(t.run(["pin"], { CF_CONFIRM: "0000" }).code, 1);
  assert.equal(t.run(["pin"], { CF_CONFIRM: "cd42" }).code, 0);
  assert.equal(t.run(["wrangler", "whoami"]).code, 0);
  assert.equal(t.run(["url"]).out.trim(), "https://countershift-ranking.cs-test.workers.dev");
});

test("after pinning, credentials for another account are refused", () => {
  const t = setup();
  t.run(["pin"], { CF_CONFIRM: "cd42" });
  writeFileSync(join(t.dir, ".cf.env"), `CLOUDFLARE_API_TOKEN=${TOKEN}\nCLOUDFLARE_ACCOUNT_ID=${OTHER}\n`);
  chmodSync(join(t.dir, ".cf.env"), 0o600);
  world.accounts = [{ id: OTHER, name: "B" }];
  assert.match(t.run(["wrangler", "whoami"]).out, /different account than the pinned/);
});

test("read-only commands run; changing commands need the confirmation", () => {
  const t = setup();
  t.run(["pin"], { CF_CONFIRM: "cd42" });
  for (const args of [["d1", "list"], ["deploy", "--dry-run"], ["d1", "execute", "x", "--local", "--file=schema.sql"], ["deployments", "list"]]) {
    assert.equal(t.run(["wrangler", ...args]).code, 0, args.join(" "));
  }
  for (const args of [["deploy"], ["d1", "create", "countershift-ranking"], ["d1", "execute", "countershift-ranking", "--remote", "--file=schema.sql"],
    ["secret", "put", "RATE_SALT"], ["delete"], ["rollback"], ["d1", "time-travel", "restore", "x"], ["kv", "namespace", "create", "x"], ["some-future-command"]]) {
    const r = t.run(["wrangler", ...args]);
    assert.equal(r.code, 1, args.join(" "));
    assert.match(r.out, /changes the account/, args.join(" "));
  }
  assert.equal(t.run(["wrangler", "deploy"], { CF_CONFIRM: "cd42" }).code, 0);
  for (const args of [["login"], ["logout"], ["auth", "token"], ["whoami", "--profile", "x"]]) assert.match(t.run(["wrangler", ...args]).out, /not run through this tool/);
});

test("wrangler gets only the COUNTERSHIFT token, its own settings directory, and no other credentials", () => {
  const t = setup();
  t.run(["pin"], { CF_CONFIRM: "cd42" });
  const r = t.run(["wrangler", "d1", "list"]);
  assert.equal(r.code, 0, r.out);
  assert.match(r.called, /ARGS d1 list/);
  assert.match(r.called, new RegExp("TOKEN " + TOKEN));
  assert.match(r.called, new RegExp("ACCOUNT " + ID));
  assert.match(r.called, new RegExp("XDG " + join(t.dir, "home").replace(/[/.]/g, "\\$&")));
  assert.match(r.called, /KEY \[\]/);
  assert.match(r.called, /EMAIL \[\]/);
  assert.match(r.called, /BASE \[\]/);
  assert.ok(!r.out.includes(TOKEN) && !r.out.includes(ID));
});

test("status shows bindings by name and whether the Worker is public; no values, no ids", () => {
  const t = setup();
  t.run(["pin"], { CF_CONFIRM: "cd42" });
  assert.match(t.run(["status"]).out, /no Worker called countershift-ranking/);
  world.workers = ["countershift-ranking"]; world.dbs = ["countershift-ranking"];
  let r = t.run(["status"]);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /binding DB: d1 -> D1 "countershift-ranking"/);
  assert.match(r.out, /binding RATE_SALT: secret_text/);
  assert.match(r.out, /binding RL_READ: ratelimit 60\/60s/);
  assert.match(r.out, /workers\.dev route: disabled/);
  assert.match(r.out, /version \(preview\) URLs: disabled/);
  assert.ok(!r.out.includes(ID) && !r.out.includes(TOKEN) && !r.out.includes("db-uuid-0001"));
  world.public = true;
  assert.match(t.run(["status"]).out, /workers\.dev route: ENABLED \(public\)/);
});
