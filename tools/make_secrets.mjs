#!/usr/bin/env node
// Creates server/.prod.secrets.json (git-ignored, mode 600) with the three secrets of the
// ranking API, as random values. It never prints a value and never overwrites an existing file.
// The same file is given to `wrangler deploy --secrets-file`, and read by the verifier and admin tools.
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const SECRETS_FILE = join(dirname(fileURLToPath(import.meta.url)), "..", "server", ".prod.secrets.json");
const NAMES = ["RATE_SALT", "VERIFIER_TOKEN", "ADMIN_TOKEN"];

/** Reads one secret for the local tools (verifier, admin). */
export function readSecret(name, file = SECRETS_FILE) {
  if (!existsSync(file)) throw new Error(file + " is missing (run: node tools/make_secrets.mjs)");
  if ((statSync(file).mode & 0o077) !== 0) throw new Error(file + " can be read by others (chmod 600)");
  const v = JSON.parse(readFileSync(file, "utf8"))[name];
  if (typeof v !== "string" || v.length < 32) throw new Error(name + " is missing in " + file);
  return v;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === "check") {
    for (const n of NAMES) console.log(`${n}: set, ${readSecret(n).length} characters`);
    console.log("distinct: " + (new Set(NAMES.map((n) => readSecret(n))).size === NAMES.length));
  } else if (existsSync(SECRETS_FILE)) {
    console.log("server/.prod.secrets.json already exists; nothing was changed. (node tools/make_secrets.mjs check)");
  } else {
    const o = {};
    for (const n of NAMES) o[n] = randomBytes(32).toString("hex");
    writeFileSync(SECRETS_FILE, JSON.stringify(o, null, 2) + "\n", { mode: 0o600 });
    console.log("created server/.prod.secrets.json with " + NAMES.join(", ") + " (64 characters each; values not shown)");
  }
}
