'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { deflateSync, inflateSync } = require('node:zlib');
const core = require('./core.cjs');
const MAX_BYTES = 512 * 1024 * 1024;
const MAX_RECORD = 4 * 1024 * 1024;
const APPLICATION = 0x494d4452;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

async function openInventory(file) {
  core.insist(path.isAbsolute(file), 'absolute-inventory-path-required');
  const directory = path.dirname(file);
  const real = await fs.realpath(directory);
  core.insist(path.resolve(real).toLowerCase() === path.resolve(directory).toLowerCase(), 'unsafe-inventory-directory');
  try {
    const item = await fs.lstat(file);
    core.insist(item.isFile() && !item.isSymbolicLink() && item.nlink === 1 && item.size <= MAX_BYTES, 'unsafe-inventory-file');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    const handle = await fs.open(file, 'wx', 0o600); await handle.close();
  }
  const { DatabaseSync } = require('node:sqlite');
  const db = new DatabaseSync(file);
  try {
    db.exec('PRAGMA busy_timeout=1000; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;');
    const application = db.prepare('PRAGMA application_id').get().application_id;
    const version = db.prepare('PRAGMA user_version').get().user_version;
    core.insist((application === 0 && version === 0) || (application === APPLICATION && version === 1), 'unsupported-inventory-format');
    if (application === 0) {
      core.insist(db.prepare("SELECT count(*) AS count FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").get().count === 0, 'foreign-inventory-file');
      db.exec(`BEGIN IMMEDIATE;
        CREATE TABLE source (
          assetId TEXT PRIMARY KEY, ownerId TEXT NOT NULL, sourcePath TEXT NOT NULL,
          sourceStat TEXT, extraction TEXT, sourceReadAt TEXT, checkedAt TEXT NOT NULL,
          raw BLOB, rawDigest TEXT, outcome TEXT, dates TEXT
        );
        CREATE TABLE progress (
          ownerId TEXT PRIMARY KEY, updatedAt TEXT NOT NULL, status TEXT NOT NULL,
          cursor TEXT, inspected INTEGER NOT NULL, proposed INTEGER NOT NULL,
          timezone TEXT NOT NULL, upstreamCommit TEXT NOT NULL
        );
        PRAGMA application_id=${APPLICATION}; PRAGMA user_version=1; COMMIT;`);
    }
    const pageSize = db.prepare('PRAGMA page_size').get().page_size;
    db.exec(`PRAGMA max_page_count=${Math.floor(MAX_BYTES / pageSize)};`);
    const read = db.prepare('SELECT sourcePath, sourceStat, extraction, raw, rawDigest FROM source WHERE assetId=? AND ownerId=?');
    const put = db.prepare(`INSERT INTO source(assetId,ownerId,sourcePath,sourceStat,extraction,sourceReadAt,checkedAt,raw,rawDigest)
      VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(assetId) DO UPDATE SET ownerId=excluded.ownerId,
      sourcePath=excluded.sourcePath,sourceStat=excluded.sourceStat,extraction=excluded.extraction,
      sourceReadAt=excluded.sourceReadAt,checkedAt=excluded.checkedAt,raw=excluded.raw,rawDigest=excluded.rawDigest`);
    const inspect = db.prepare(`INSERT INTO source(assetId,ownerId,sourcePath,checkedAt,outcome,dates) VALUES(?,?,?,?,?,?)
      ON CONFLICT(assetId) DO UPDATE SET checkedAt=excluded.checkedAt,outcome=excluded.outcome,dates=excluded.dates`);
    const progress = db.prepare(`INSERT INTO progress VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(ownerId) DO UPDATE SET
      updatedAt=excluded.updatedAt,status=excluded.status,cursor=excluded.cursor,
      inspected=excluded.inspected,proposed=excluded.proposed,timezone=excluded.timezone,upstreamCommit=excluded.upstreamCommit`);
    function transaction(fn) {
      db.exec('BEGIN IMMEDIATE');
      try { fn(); db.exec('COMMIT'); } catch (error) {
        db.exec('ROLLBACK');
        if (error.errcode === 13) throw new core.Stop('inventory-capacity-full');
        throw error;
      }
    }
    return {
      close() { db.close(); },
      summary() {
        return { ...db.prepare(`SELECT count(*) AS imagesInspected, count(raw) AS reusableMetadata,
          min(sourceReadAt) AS firstSourceReadAt, max(sourceReadAt) AS lastSourceReadAt,
          max(checkedAt) AS lastCheckedAt FROM source`).get(),
          capacityBytes: db.prepare('PRAGMA max_page_count').get().max_page_count * pageSize,
          progress: db.prepare('SELECT * FROM progress ORDER BY ownerId').all() };
      },
      get({ id, ownerId, file, stat, extraction }) {
        const row = read.get(id, ownerId);
        if (!row || row.sourcePath !== file || row.sourceStat !== core.stable(stat) || row.extraction !== extraction || row.raw === null) return null;
        core.insist(row.raw.byteLength <= 64 * 1024, 'inventory-metadata-too-large');
        const bytes = inflateSync(row.raw, { maxOutputLength: MAX_RECORD });
        core.insist(digest(bytes) === row.rawDigest, 'inventory-metadata-digest-mismatch');
        return JSON.parse(bytes.toString('utf8'));
      },
      put(records) {
        const now = new Date().toISOString();
        const prepared = records.map(record => {
          const bytes = Buffer.from(JSON.stringify(record.raw));
          const compressed = bytes.length <= MAX_RECORD ? deflateSync(bytes) : null;
          const raw = compressed && compressed.length <= 64 * 1024 ? compressed : null;
          return [record.id, record.ownerId, record.file, core.stable(record.stat), record.extraction, now, now, raw, raw ? digest(bytes) : null];
        });
        transaction(() => { for (const record of prepared) put.run(...record); });
      },
      inspected(records) {
        const now = new Date().toISOString();
        transaction(() => {
          for (const { snapshot, reason, after } of records) inspect.run(snapshot.asset.id, snapshot.asset.ownerId,
            snapshot.asset.originalPath, now, reason || 'proposed', after ? JSON.stringify(after) : null);
        });
      },
      progress(ownerId, identity, state) {
        progress.run(ownerId, new Date().toISOString(), state.status, state.cursor || null,
          state.inspected, state.proposed, identity.timezone, identity.upstreamCommit);
      },
    };
  } catch (error) { db.close(); throw error; }
}
module.exports = { openInventory, MAX_BYTES };
