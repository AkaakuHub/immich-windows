'use strict';
// Imported only by explicit runtime commands. Never import main/AppModule, build
// Nest, run migrations, request jobs, or use updateAsset/extract handlers.
const fs = require('node:fs/promises');
const path = require('node:path');
const { createRequire } = require('node:module');
const { createHash } = require('node:crypto');
const core = require('./core.cjs');
const PIN = 'db355f79d910bbfc6378117ed10868493c97b922';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function normalized(p) { const v = path.resolve(p); return process.platform === 'win32' ? v.toLowerCase() : v; }
async function regularPath(p) {
  const s = await fs.lstat(p, { bigint: true });
  core.insist(s.isFile() && !s.isSymbolicLink(), 'source-not-regular-file');
  const real = await fs.realpath(p);
  core.insist(normalized(real) === normalized(p), 'source-link-or-reparse-path');
  return { s, real };
}
function statToken(s, real) { return { real: normalized(real), dev: String(s.dev), ino: String(s.ino), mode: String(s.mode), nlink: String(s.nlink), size: String(s.size), mtimeNs: String(s.mtimeNs), ctimeNs: String(s.ctimeNs), birthtimeNs: String(s.birthtimeNs) }; }
const ASSET_FIELDS = ['id', 'ownerId', 'originalPath', 'fileCreatedAt', 'localDateTime', 'fileModifiedAt', 'updatedAt', 'updateId', 'isEdited', 'isOff…316 tokens truncated…positories/config.repository.js', 'dist/utils/database.js', 'dist/enum.js', 'package.json'];
  const hashes = {};
  for (const file of runtimeFiles) hashes[file] = createHash('sha256').update(await fs.readFile(path.join(server, file))).digest('hex');
  const quiet = { log: console.log, info: console.info, warn: console.warn, error: console.error, debug: console.debug };
  // Upstream modules / database notices can print raw paths or SQL parameters.
  // This isolated CLI prints only its sanitized result records via stdout.write.
  for (const key of Object.keys(quiet)) console[key] = () => {};
  const originalCwd = process.cwd();
  process.chdir(release);
  let db, metadataRepository;
  let warnings = 0;
  const logger = { setContext() {}, verbose() {}, debug() {}, log() {}, warn() { warnings++; }, error() { warnings++; }, fatal() { warnings++; } };
  try {
    req('reflect-metadata');
    const { MetadataService, firstDateTime } = req(path.join(server, runtimeFiles[0]));
    const { MetadataRepository } = req(path.join(server, runtimeFiles[1]));
    const { ConfigRepository } = req(path.join(server, runtimeFiles[2]));
    const { getKyselyConfig } = req(path.join(server, runtimeFiles[3]));
    const { AssetFileType, AssetType } = req(path.join(server, runtimeFiles[4]));
    const { DateTime } = req('luxon');
    const { Kysely, sql } = req('kysely');
    core.insist(AssetFileType.Sidecar === 'sidecar' && AssetType.Image === 'IMAGE', 'unsupported-runtime-enums');
    core.insist(typeof MetadataService.prototype.getDates === 'function' && typeof firstDateTime === 'function', 'unsupported-runtime-methods');
    const timezone = DateTime.local().zoneName;
    core.insist(typeof timezone === 'string' && DateTime.local().isValid, 'invalid-runtime-timezone');
    const getDates = (asset, tags, stats) => {
      const result = MetadataService.prototype.getDates.call({ logger }, { ...asset, fileCreatedAt: new Date(asset.fileCreatedAt) }, tags, stats);
      return { dateTimeOriginal: result.dateTimeOriginal.toISOString(), localDateTime: result.localDateTime.toISOString(), timeZone: result.timeZone };
    };
    // Actual installed method, synthetic inputs, no media access or DB connection.
    for (const instant of ['2024-01-15T12:34:56.789Z', '2024-07-15T12:34:56.789Z']) {
      const ms = Date.parse(instant);
      const result = getDates({ id: 'synthetic', originalPath: 'synthetic.png', fileCreatedAt: instant }, {}, { birthtimeMs: ms, mtimeMs: ms + 1, mtime: new Date(ms + 1) });
      core.insist(core.same(result, { dateTimeOriginal: instant, localDateTime: DateTime.fromISO(instant, { zone: timezone }).setZone('UTC', { keepLocalTime: true }).toJSDate().toISOString(), timeZone: timezone }), 'installed-patch-self-test-failed');
    }
    core.insist(firstDateTime({ DateTimeOriginal: '2024:05:01 12:34:56' }), 'capture-date-parser-self-test-failed');
    core.insist(!firstDateTime({}), 'empty-date-parser-self-test-failed');
    const toolHashes = {};
    for (const file of ['core.cjs','runtime.cjs','cli.cjs','guided.cjs']) toolHashes[file] = createHash('sha256').update(await fs.readFile(path.join(__dirname,file))).digest('hex');
    const identity = { upstreamCommit: PIN, version: manifest.immichVersion, node: process.version, platform: process.platform, timezone, files: hashes, toolHashes };
    if (connect) {
      const config = new ConfigRepository().getEnv().database.config;
      const { log: _unredactedLog, ...kyselyConfig } = getKyselyConfig(config);
      db = new Kysely({ ...kyselyConfig, log() {} });
    }
    const readOnly = fn => db.transaction().setIsolationLevel('repeatable read').execute(async tx => { await sql`set transaction read only`.execute(tx); await sql`set local statement_timeout = '15000ms'`.execute(tx); return fn(tx); });
    const close = async () => { let error; try { await metadataRepository?.teardown(); } catch (e) { error = e; } try { await db?.destroy(); } catch (e) { error ||= e; } for (const [key, fn] of Object.entries(quiet)) console[key] = fn; process.chdir(originalCwd); if (error) throw new core.Stop('cleanup-failed'); };
    if (usersOnly) {
      // This object cannot read media or mutate assets. ExifTool is constructed
      // only by readMetadata below, never for the account selection screen.
      return { identity, close, async listUsers() {
        const rows = await readOnly(tx => tx.selectFrom('user').select(['id','name','email']).where('deletedAt', 'is', null).orderBy('name').orderBy('id').limit(1001).execute());
        core.insist(rows.length <= 1000 && rows.every(row => UUID.test(row.id) && typeof row.name === 'string' && typeof row.email === 'string'), 'unsupported-user-list');
        return rows;
      } };
    }
    const selectFields = (alias, fields) => fields.map(f => DATE_FIELDS.has(f) ? sql`to_char(${sql.ref(alias + '.' + f)} at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`.as(alias + '_' + f) : sql.ref(alias + '.' + f).as(alias + '_' + f));
    const baseQuery = tx => tx.selectFrom('asset as a').innerJoin('asset_exif as e', 'e.assetId', 'a.id').select([...selectFields('a', ASSET_FIELDS), ...selectFields('e', EXIF_FIELDS),
      sql`coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'type', f.type, 'path', f.path) order by f.id) from asset_file f where f."assetId" = a.id and f.type = 'sidecar'), '[]'::jsonb)`.as('linkedSidecars'),
      sql`exists(select 1 from asset r where r."livePhotoVideoId" = a.id)`.as('reverseLive'),
    ]).where('a.ownerId', '=', ownerId);
    async function fromRow(tx, row) {
      if (!row) return null;
      const asset = Object.fromEntries(ASSET_FIELDS.map(f => [f, row['a_' + f]]));
      const exif = Object.fromEntries(EXIF_FIELDS.map(f => [f, row['e_' + f]]));
      if (exif.lockedProperties === null) exif.lockedProperties = []; // schema's null = no locks
      // Normalize dates only where millisecond precision is exact; preserve the
      // full update timestamps as text for snapshot CAS, not Date truncation.
      for (const object of [asset, exif]) for (const field of Object.keys(object)) if (DATE_FIELDS.has(field) && object[field] !== null && field !== 'updatedAt') {
        const value = object[field];
        if (/\.\d{3}000Z$/.test(value)) object[field] = new Date(value).toISOString();
      }
      return { asset, exif, sidecars: row.linkedSidecars, reverseLiveLinks: row.reverseLive ? 1 : 0 };
    }
    const snapshot = async (tx, id, lock = false) => {
      core.insist(UUID.test(id), 'invalid-asset-id');
      let q = baseQuery(tx).where('a.id', '=', id);
      if (lock) q = q.forUpdate(['a', 'e']);
      return fromRow(tx, await q.executeTakeFirst());
    };
    const adapter = {
      identity, firstDateTime, getDates,
      close,
      async stat(p) { const { s, real } = await regularPath(p); return { token: statToken(s, real), stats: { birthtimeMs: Number(s.birthtimeNs / 1000000n) + Number(s.birthtimeNs % 1000000n) / 1e6, mtimeMs: Number(s.mtimeNs / 1000000n) + Number(s.mtimeNs % 1000000n) / 1e6, mtime: new Date(Number(s.mtimeNs / 1000000n)) } }; },
      async sidecarsAbsent(p) {
        const base = path.join(path.dirname(p), path.parse(p).name);
        core.insist(process.platform === 'win32', 'windows-runtime-required');
        for (const candidate of new Set([p + '.xmp', base + '.xmp'])) {
          try { await fs.lstat(candidate); return false; } catch (e) { if (e.code !== 'ENOENT') throw new core.Stop('sidecar-check-failed'); }
        }
        return true;
      },
      async readMetadata(p) {
        if (!metadataRepository) {
          metadataRepository = new MetadataRepository(logger);
          metadataRepository.setMaxConcurrency(1);
        }
        const before = warnings;
        const tags = await metadataRepository.readTags(p);
        core.insist(before === warnings, 'metadata-reader-warning');
        core.insist(typeof tags?.SourceFile === 'string' && normalized(tags.SourceFile) === normalized(p), 'metadata-source-mismatch');
        return { tags: { ...tags, SourceFile: normalized(tags.SourceFile) }, canonicalSourcePath: normalized(p) };
      },
      metadataEvidence(tags) { return Object.fromEntries(['MIMEType', ...core.CAPTURE_TAGS, ...core.ZONE_TAGS, ...core.MOTION_TAGS].filter(k => tags[k] !== undefined).map(k => [k, tags[k]])); },
      async candidates({ afterId, limit }) {
        return readOnly(async tx => {
          let q = baseQuery(tx).where('a.type', '=', 'IMAGE').where('a.isOffline', '=', false).where('a.isEdited', '=', false).where('a.deletedAt', 'is', null).where('a.livePhotoVideoId', 'is', null).where('e.timeZone', 'is', null).whereRef('a.fileCreatedAt', '=', 'a.localDateTime').whereRef('a.fileCreatedAt', '=', 'e.dateTimeOriginal');
          if (afterId) q = q.where('a.id', '>', afterId);
          const rows = await q.orderBy('a.id', 'asc').limit(limit).execute();
          const out = []; for (const row of rows) out.push(await fromRow(tx, row)); return out;
        });
      },
      snapshot: id => readOnly(tx => snapshot(tx, id)),
      async snapshots(ids) {
        core.insist(Array.isArray(ids) && ids.length >= 1 && ids.length <= 100 && ids.every(id => UUID.test(id)) && new Set(ids).size === ids.length, 'invalid-snapshot-batch');
        return readOnly(async tx => {
          const rows = await baseQuery(tx).where('a.id', 'in', ids).orderBy('a.id', 'asc').execute();
          const result = []; for (const row of rows) result.push(await fromRow(tx, row)); return result;
        });
      },
      transaction: fn => db.transaction().setIsolationLevel('serializable').execute(async tx => {
        await sql`set local lock_timeout = '1000ms'`.execute(tx);
        await sql`set local statement_timeout = '15000ms'`.execute(tx);
        return fn({
          snapshotForUpdate: id => snapshot(tx, id, true),
          async updateDates(expected, dates) {
            core.insist(expected.asset.ownerId === ownerId && expected.exif.assetId === expected.asset.id, 'owner-scope-mismatch');
            // Fields are fixed in code; no table/column/value selection from CLI.
            const a = expected.asset, e = expected.exif;
            const ar = await tx.updateTable('asset').set({ localDateTime: new Date(dates.localDateTime) }).where('id', '=', a.id).where('ownerId', '=', ownerId).where('updateId', '=', a.updateId).where('fileCreatedAt', '=', new Date(a.fileCreatedAt)).where('localDateTime', '=', new Date(a.localDateTime)).returning('id').execute();
            core.insist(ar.length === 1, 'asset-cas-failed');
            let eq = tx.updateTable('asset_exif').set({ timeZone: dates.timeZone }).where('assetId', '=', a.id).where('assetId', 'in', tx.selectFrom('asset').select('id').where('ownerId', '=', ownerId).where('id', '=', a.id)).where('updateId', '=', e.updateId).where('dateTimeOriginal', '=', new Date(e.dateTimeOriginal));
            eq = e.timeZone === null ? eq.where('timeZone', 'is', null) : eq.where('timeZone', '=', e.timeZone);
            const er = await eq.returning('assetId').execute();
            core.insist(er.length === 1, 'exif-cas-failed');
            return snapshot(tx, a.id);
          },
        });
      }),
    };
    if (connect) {
      identity.database = await readOnly(async tx => (await sql`select current_database() as name, inet_server_addr()::text as address, inet_server_port() as port`.execute(tx)).rows[0]);
      // Verify actual timestamp types before applying timezone formatting. Custom
      // triggers are rejected separately, rather than silently trusting a pin.
      const schema = await readOnly(async tx => (await sql`select table_name, column_name, data_type from information_schema.columns where table_schema = current_schema() and table_name in ('asset','asset_exif')`.execute(tx)).rows);
      for (const [table, fields] of [['asset', ASSET_FIELDS], ['asset_exif', EXIF_FIELDS]]) for (const field of fields) {
        const c = schema.find(c => c.table_name === table && c.column_name === field);
        core.insist(c && (!DATE_FIELDS.has(field) || c.data_type === 'timestamp with time zone'), 'unsupported-schema');
      }
      const triggers = await readOnly(async tx => (await sql`select c.relname as table_name, t.tgname, pg_get_triggerdef(t.oid) as definition, pg_get_functiondef(t.tgfoid) as function from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and (t.tgtype::int & 16) = 16 and n.nspname=current_schema() and c.relname in ('asset','asset_exif') order by c.relname,t.tgname`.execute(tx)).rows);
      identity.schemaDigest = core.hash(schema.filter(c => ['asset','asset_exif'].includes(c.table_name)).sort((a,b) => (a.table_name+a.column_name).localeCompare(b.table_name+b.column_name)));
      identity.triggersDigest = core.hash(triggers);
      // Filled against pinned function source; unknown/custom triggers fail closed.
      for (const table of ['asset','asset_exif']) {
        const t = triggers.filter(t => t.table_name === table);
        core.insist(t.length === 1 && /before update on /i.test(t[0].definition) && /for each row execute function .*updated_at\(\)/i.test(t[0].definition), 'unsupported-database-triggers');
        const body = /\$function\$([\s\S]*?)\$function\$/i.exec(t[0].function)?.[1]?.replace(/\s+/g, ' ').trim();
        core.insist(body && /^DECLARE clock_timestamp TIMESTAMP := clock_timestamp\(\); BEGIN new\."updatedAt" = clock_timestamp; new\."updateId" = immich_uuid_v7\(clock_timestamp\); return new; END;$/i.test(body), 'unverified-updated-at-function');
      }
    }
    return adapter;
  } catch (e) {
    try { await metadataRepository?.teardown(); } catch {} try { await db?.destroy(); } catch {}
    for (const [key, fn] of Object.entries(quiet)) console[key] = fn;
    process.chdir(originalCwd);
    if (e instanceof core.Stop) throw e;
    throw new core.Stop('runtime-initialization-failed');
  }
}
module.exports = { createAdapter, statToken, normalized, PIN };
