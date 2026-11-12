// A D1-shaped wrapper over node:sqlite, for local play and tests.
// It covers what worker.js uses: prepare/bind/first/all/run and batch (one transaction).
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

export function openLocalD1(file, schemaPath) {
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec(readFileSync(schemaPath, "utf8"));
  const make = (sql, args = []) => ({
    sql, args,
    bind: (...a) => make(sql, a),
    // D1 numbers its parameters ?1..?n; a value may be used more than once
    _run() { return db.prepare(sql).run(...this._named()); },
    _named() {
      const o = {};
      args.forEach((v, i) => { o[`?${i + 1}`] = v === undefined ? null : (typeof v === "boolean" ? Number(v) : v); });
      return args.length ? [o] : [];
    },
    async first() { return db.prepare(sql).get(...this._named()) ?? null; },
    async all() { return { results: db.prepare(sql).all(...this._named()) }; },
    async run() { const r = this._run(); return { meta: { changes: Number(r.changes) } }; },
  });
  return {
    prepare: (sql) => make(sql),
    async batch(list) {
      db.exec("BEGIN");
      try {
        const out = list.map((s) => ({ meta: { changes: Number(s._run().changes) } }));
        db.exec("COMMIT");
        return out;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
    raw: db,
  };
}
