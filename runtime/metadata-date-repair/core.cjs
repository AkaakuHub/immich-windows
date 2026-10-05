'use strict';
// Pure orchestration. No database, media, network, or service access at import time.
const { createHash } = require('node:crypto');
const FORMAT = 'immich-date-repair/v1';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CAPTURE_TAGS = ['SubSecDateTimeOriginal', 'SubSecCreateDate', 'DateTimeOriginal', 'CreationDate', 'CreateDate', 'MediaCreateDate', 'DateTimeCreated', 'GPSDateTime', 'DateTimeUTC', 'SonyDateTime2', 'SourceImageCreateTime'];
const ZONE_TAGS = ['zone', 'TimeZone', 'TimeZoneOffset', 'OffsetTime', 'OffsetTimeOriginal', 'OffsetTimeDigitized', 'TimeZoneCity', 'DaylightSavings'];
const MOTION_TAGS = ['MotionPhoto', 'MicroVideo', 'MicroVideoOffset', 'MotionPhotoVideo', 'EmbeddedVideoFile', 'EmbeddedVideoType', 'ContainerDirectory', 'LivePhotoVideoIndex', 'ContentIdentifier'];
const HISTORY_WARNING = 'Deleted sidecars or historical database-only date edits can be indistinguishable from this bug. These guards cannot prove there was no past manual edit.';
class Stop extends Error { constructor(code) { super(code); this.code = code; } }
function insist(value, code) { if (!value) throw new Stop(code); }
function stable(value) { if (Array.isArray(value)) return '[' + value.map(stable).join(',') + ']'; if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + stable(value[k])).join(',') + '}'; return JSON.stringify(value); }
function hash(value) { return createHash('sha256').update(stable(value)).digest('hex'); }
function same(a, b) { return stable(a) === stable(b); }
function iso(value) { const d = new Date(value); insist(typeof value === 'string' && /Z$/.test(value) && Number.isFinite(+d), 'invalid-date'); const sub = /\.(\d+)Z$/.exec(value)?.[1] || ''; insist(!/[1-9]/.test(sub.slice(3)), 'submillisecond-date-excluded'); return d.toISOString(); }
function nonempty(value) { return value !== undefined && value !== null && value !== '' && !(Array.isArray(value) && value.length === 0); }
function beforeDates(s) { return { fileCreatedAt: s.asset.fileCreatedAt, localDateTime: s.asset.localDateTime, dateTimeOriginal: s.exif.dateTimeOriginal, timeZone: s.exif.timeZone }; }
function revisions(s) { return { asset: s.asset.updateId, exif: s.exif.updateId }; }
function initialReason(s) {
  if (!s || !s.asset || !s.exif || !UUID.test(s.asset.id) || s.exif.assetId !== s.asset.id) return 'missing-or-invalid-record';
  const a = s.asset, e = s.exif;
  if (!UUID.test(a.updateId) || !UUID.test(e.updateId)) return 'missing-revisions';
  if (a.type !== 'IMAGE' || !/\.(jpe?g|png)$/i.test(a.originalPath)) return 'unsupported-image-type';
  if (a.isEdited !== false || a.isOffline !== false || a.deletedAt !== null || a.livePhotoVideoId !== null || s.reverseLiveLinks !== 0) return 'edited-offline-deleted-or-live';
  if (e.timeZone !== null) return 'existing-timezone';
  if (!Array.isArray(e.lockedProperties) || e.lockedProperties.length !== 0) return 'metadata-locks-or-unknown';
  if (!Array.isArray(s.sidecars) || s.sidecars.length) return 'linked-sidecar';
  try { if (iso(a.fileCreatedAt) !== iso(a.localDateTime) || iso(a.fileCreatedAt) !== iso(e.dateTimeOriginal)) return 'date-fields-differ'; insist([a.fileModifiedAt, a.updatedAt, e.updatedAt].every(v => typeof v === 'string' && /Z$/.test(v) && Number.isFinite(Date.parse(v))), 'invalid-snapshot-date'); } catch (e) { return e.code || 'invalid-date'; }
  return null;
}
function strictTags(tags, sourcePath, parseCapture) {
  insist(tags && typeof tags === 'object' && !Array.isArray(tags) && Object.keys(tags).length > 1, 'metadata-empty');
  insist(typeof tags.SourceFile === 'string' && sourcePath === tags.SourceFile, 'metadata-source-mismatch');
  insist(['image/jpeg', 'image/png'].includes(tags.MIMEType), 'metadata-mime-excluded');
  for (const key of Object.keys(tags)) if (/warning|error/i.test(key) && nonempty(tags[key])) throw new Stop('metadata-warning');
  insist(!parseCapture(tags), 'capture-date-present');
  insist(!CAPTURE_TAGS.some(k => nonempty(tags[k])), 'unparsed-capture-date-present');
  insist(!ZONE_TAGS.some(k => nonempty(tags[k])), 'source-timezone-present');
  insist(!MOTION_TAGS.some(k => nonempty(tags[k])), 'motion-or-live-metadata');
}
async function verifySource(adapter, s) {
  const actual = iso(s.asset.fileCreatedAt);
  const start = await adapter.stat(s.asset.originalPath);
  // Reject definite filesystem-date mismatches before opening the original for metadata.
  const initialMillis = start.stats.birthtimeMs ? Math.min(start.stats.mtimeMs, start.stats.birthtimeMs) : start.stats.mtime.getTime();
  insist(new Date(initialMillis).toISOString() === actual, 'stored-instant-not-filesystem-anchored');
  insist((await adapter.sidecarsAbsent(s.asset.originalPath)), 'sibling-sidecar');
  const metadata = await adapter.readMetadata(s.asset.originalPath);
  strictTags(metadata.tags, metadata.canonicalSourcePath, adapter.firstDateTime);
  const end = await adapter.stat(s.asset.originalPath);
  insist(same(start.token, end.token), 'source-changed-during-read');
  insist(await adapter.sidecarsAbsent(s.asset.originalPath), 'sibling-sidecar');
  const result = adapter.getDates(s.asset, metadata.tags, end.stats);
  const diskMillis = end.stats.birthtimeMs ? Math.min(end.stats.mtimeMs, end.stats.birthtimeMs) : end.stats.mtime.getTime();
  insist(new Date(diskMillis).toISOString() === actual, 'stored-instant-not-filesystem-anchored');
  insist(iso(result.dateTimeOriginal) === actual && iso(s.exif.dateTimeOriginal) === actual, 'fallback-instant-differs');
  insist(result.timeZone === adapter.identity.timezone, 'fallback-timezone-differs');
  insist(iso(result.localDateTime) !== iso(s.asset.localDateTime), 'no-wall-clock-change');
  return { stat: end.token, metadataDigest: hash(adapter.metadataEvidence(metadata.tags)), after: { fileCreatedAt: s.asset.fileCreatedAt, localDateTime: iso(result.localDateTime), dateTimeOriginal: s.exif.dateTimeOriginal, timeZone: result.timeZone } };
}
async function plan(adapter, options) {
  insist(UUID.test(options.ownerId), 'owner-id-required');
  insist(Number.isInteger(options.limit) && options.limit >= 1 && options.limit <= 1000, 'invalid-limit');
  insist(Number.isInteger(options.pageSize) && options.pageSize >= 1 && options.pageSize <= 100, 'invalid-page-size');
  if (options.afterId) insist(UUID.test(options.afterId), 'invalid-after-id');
  const output = { format: FORMAT, createdAt: new Date().toISOString(), identity: structuredClone(adapter.identity), historyWarning: HISTORY_WARNING, scope: { ownerId: options.ownerId, limit: options.limit, pageSize: options.pageSize, afterId: options.afterId || null }, inspected: 0, nextAfterId: null, exhausted: false, entries: [], excluded: [] };
  let cursor = options.afterId || null;
  const seen = new Set();
  while (output.inspected < options.limit) {
    const count = Math.min(options.pageSize, options.limit - output.inspected);
    const rows = await adapter.candidates({ ownerId: options.ownerId, afterId: cursor, limit: count });
    insist(Array.isArray(rows) && rows.length <= count, 'invalid-page');
    if (!rows.length) { output.exhausted = true; break; }
    const pending = [];
    for (const snapshot of rows) {
      const id = snapshot.asset?.id;
      insist(UUID.test(id) && (!cursor || id > cursor) && !seen.has(id), 'invalid-keyset-order');
      insist(snapshot.asset.ownerId === options.ownerId, 'owner-scope-mismatch');
      seen.add(id); cursor = id; output.inspected++;
      let reason = initialReason(snapshot);
      if (!reason) {
        try { pending.push({ id, snapshot, ...await verifySource(adapter, snapshot) }); }
        catch (e) { if (!(e instanceof Stop)) throw e; reason = e.code; }
      }
      if (reason) output.excluded.push({ id, reason });
    }
    if (pending.length) {
      insist(typeof adapter.snapshots === 'function', 'batch-snapshots-required');
      const ids = new Set(pending.map(entry => entry.id));
      const current = await adapter.snapshots([...ids]);
      insist(Array.isArray(current), 'invalid-snapshot-batch');
      const byId = new Map();
      for (const snapshot of current) {
        const id = snapshot?.asset?.id;
        insist(ids.has(id) && snapshot.asset.ownerId === options.ownerId && !byId.has(id), 'invalid-snapshot-batch');
        byId.set(id, snapshot);
      }
      for (const entry of pending) {
        if (same(byId.get(entry.id), entry.snapshot)) output.entries.push(entry);
        else output.excluded.push({ id: entry.id, reason: 'snapshot-changed-during-plan' });
      }
    }
    options.onProgress?.({ inspected: output.inspected, proposed: output.entries.length });
    if (rows.length < count) { output.exhausted = true; break; }
  }
  output.nextAfterId = output.exhausted ? null : cursor;
  return output;
}
function validatePlan(p, adapter, approvedDigest) {
  insist(p && p.format === FORMAT && p.historyWarning === HISTORY_WARNING, 'invalid-plan-format');
  insist(hash(p) === approvedDigest, 'plan-digest-not-approved');
  insist(same(p.identity, adapter.identity), 'runtime-or-timezone-changed');
  insist(Array.isArray(p.entries) && p.entries.length <= p.scope.limit && p.entries.length <= 1000, 'invalid-plan-entries');
  const ids = new Set();
  for (const e of p.entries) { insist(UUID.test(e.id) && e.id === e.snapshot.asset.id && !ids.has(e.id) && e.snapshot.asset.ownerId === p.scope.ownerId, 'invalid-plan-entry'); ids.add(e.id); insist(!initialReason(e.snapshot), 'ineligible-plan-entry'); insist(e.after.fileCreatedAt === e.snapshot.asset.fileCreatedAt && e.after.dateTimeOriginal === e.snapshot.exif.dateTimeOriginal, 'plan-changes-actual-instant'); }
}
async function apply(adapter, p, options, journal) {
  insist(options.acknowledgeHistoryAmbiguity === true, 'historical-ambiguity-not-acknowledged');
  validatePlan(p, adapter, options.approvedDigest);
  await journal.header({ format: FORMAT, operation: 'apply', planDigest: options.approvedDigest });
  const completed = [];
  for (const e of p.entries) {
    const current = await adapter.snapshot(e.id);
    insist(same(current, e.snapshot), 'stale-plan');
    const evidence = await verifySource(adapter, current);
    insist(same(evidence, { stat: e.stat, metadataDigest: e.metadataDigest, after: e.after }), 'source-or-calculation-changed');
    const result = await adapter.transaction(async tx => {
      // All ExifTool I/O is above. The transaction only checks metadata, a final stat,
      // sidecar existence and exact revision/value CAS, then writes two date fields.
      const locked = await tx.snapshotForUpdate(e.id);
      insist(same(locked, e.snapshot), 'transaction-snapshot-changed');
      insist(await adapter.sidecarsAbsent(current.asset.originalPath), 'sibling-sidecar');
      insist(same((await adapter.stat(current.asset.originalPath)).token, e.stat), 'source-changed-before-write');
      const afterSnapshot = await tx.updateDates(e.snapshot, e.after);
      assertChangedOnlyDates(e.snapshot, afterSnapshot, e.after);
      const record = { kind: 'prepared', id: e.id, before: beforeDates(e.snapshot), after: e.after, beforeRevisions: revisions(e.snapshot), afterRevisions: revisions(afterSnapshot) };
      await journal.appendSync(record); // MUST fsync before callback returns/COMMIT
      return record;
    });
    // On uncertainty here, stop. Prepared record allows read-only reconciliation.
    await journal.appendSync({ kind: 'committed', id: e.id, afterRevisions: result.afterRevisions });
    completed.push(e.id);
  }
  await journal.appendSync({ kind: 'complete', count: completed.length });
  return completed;
}
function assertChangedOnlyDates(before, after, dates) {
  const expected = structuredClone(before);
  expected.asset.localDateTime = dates.localDateTime;
  expected.exif.timeZone = dates.timeZone;
  for (const name of ['asset', 'exif']) {
    insist(UUID.test(after[name].updateId) && after[name].updateId !== before[name].updateId, 'missing-new-revision');
    expected[name].updateId = after[name].updateId; expected[name].updatedAt = after[name].updatedAt;
  }
  insist(same(expected, after), 'unexpected-database-change');
}
async function reconcile(adapter, records) {
  const output = [];
  for (const r of records.filter(r => r.kind === 'prepared')) {
    const current = await adapter.snapshot(r.id);
    const state = current && same(beforeDates(current), r.after) && same(revisions(current), r.afterRevisions) ? 'applied-unchanged' : current && same(beforeDates(current), r.before) && same(revisions(current), r.beforeRevisions) ? 'not-applied-unchanged' : 'changed-or-ambiguous';
    output.push({ id: r.id, state });
  }
  return output;
}
async function undo(adapter, p, sourceRecords, options, journal) {
  insist(options.acknowledgeHistoryAmbiguity === true, 'historical-ambiguity-not-acknowledged');
  validatePlan(p, adapter, options.approvedDigest);
  insist(options.approvedJournalDigest === hash(sourceRecords), 'journal-digest-not-approved');
  insist(sourceRecords[0]?.operation === 'apply' && sourceRecords[0]?.planDigest === options.approvedDigest, 'journal-plan-mismatch');
  const prepared = sourceRecords.filter(r => r.kind === 'prepared');
  insist(new Set(prepared.map(r => r.id)).size === prepared.length, 'duplicate-journal-id');
  await journal.header({ format: FORMAT, operation: 'undo', planDigest: options.approvedDigest, sourceJournalDigest: options.approvedJournalDigest });
  const done = [];
  for (const r of prepared) {
    const e = p.entries.find(e => e.id === r.id);
    insist(e && same(r.before, beforeDates(e.snapshot)) && same(r.after, e.after) && same(r.beforeRevisions, revisions(e.snapshot)), 'journal-entry-mismatch');
    const current = await adapter.snapshot(r.id);
    insist(current && same(beforeDates(current), r.after) && same(revisions(current), r.afterRevisions), 'undo-state-changed-or-not-applied');
    const expected = structuredClone(e.snapshot);
    expected.asset.localDateTime = r.after.localDateTime; expected.exif.timeZone = r.after.timeZone;
    for (const name of ['asset', 'exif']) { expected[name].updateId = current[name].updateId; expected[name].updatedAt = current[name].updatedAt; }
    insist(same(current, expected), 'undo-snapshot-changed');
    insist(await adapter.sidecarsAbsent(current.asset.originalPath), 'sibling-sidecar');
    insist(same((await adapter.stat(current.asset.originalPath)).token, e.stat), 'undo-source-changed');
    const result = await adapter.transaction(async tx => {
      insist(same(await tx.snapshotForUpdate(r.id), current), 'undo-transaction-snapshot-changed');
      insist(await adapter.sidecarsAbsent(current.asset.originalPath), 'sibling-sidecar');
      insist(same((await adapter.stat(current.asset.originalPath)).token, e.stat), 'undo-source-changed');
      const afterSnapshot = await tx.updateDates(current, r.before);
      assertChangedOnlyDates(current, afterSnapshot, r.before);
      const record = { kind: 'prepared', id: r.id, before: r.after, after: r.before, beforeRevisions: r.afterRevisions, afterRevisions: revisions(afterSnapshot) };
      await journal.appendSync(record); return record;
    });
    await journal.appendSync({ kind: 'committed', id: r.id, afterRevisions: result.afterRevisions }); done.push(r.id);
  }
  await journal.appendSync({ kind: 'complete', count: done.length }); return done;
}

const INDEX_FORMAT = 'immich-date-repair/index-v1';
async function planAll(adapter, options, storeChunk) {
  const maximum = options.maxCandidates == null ? null : options.maxCandidates;
  insist(maximum === null || (Number.isSafeInteger(maximum) && maximum >= 1), 'invalid-total-bound');
  const index = { format: INDEX_FORMAT, createdAt: new Date().toISOString(), identity: structuredClone(adapter.identity), historyWarning: HISTORY_WARNING, scope: { ownerId: options.ownerId, maxCandidates: maximum, chunkSize: 1000 }, inspected: 0, proposed: 0, exhausted: false, nextAfterId: options.afterId || null, chunks: [] };
  while (maximum === null || index.inspected < maximum) {
    const p = await plan(adapter, { ownerId: options.ownerId, limit: maximum === null ? 1000 : Math.min(1000, maximum-index.inspected), pageSize: options.pageSize, afterId: index.nextAfterId, onProgress: progress => options.onProgress?.({ inspected: index.inspected + progress.inspected, proposed: index.proposed + progress.proposed }) });
    if (p.inspected === 0 && p.exhausted && index.chunks.length) {
      index.exhausted = true; index.nextAfterId = null; break;
    }
    if (maximum !== null && !p.exhausted && index.inspected + p.inspected === maximum) {
      const next = await adapter.candidates({ ownerId: options.ownerId, afterId: p.nextAfterId, limit: 1 });
      insist(Array.isArray(next) && next.length <= 1, 'invalid-boundary-page');
      if (!next.length) { p.exhausted = true; p.nextAfterId = null; }
      else insist(UUID.test(next[0]?.asset?.id) && next[0].asset.id > p.nextAfterId && next[0].asset.ownerId === options.ownerId, 'invalid-boundary-page');
    }
    index.chunks.push({ ...(await storeChunk(p,index.chunks.length+1)), planDigest: hash(p), inspected: p.inspected, proposed: p.entries.length });
    index.inspected += p.inspected; index.proposed += p.entries.length; index.exhausted = p.exhausted; index.nextAfterId = p.nextAfterId;
    if (p.exhausted) break;
    insist(p.inspected > 0 && p.nextAfterId, 'batch-made-no-progress');
  }
  return index;
}
async function applyAll(adapter, index, options, readChunk, openJournal) {
  insist(options.acknowledgeHistoryAmbiguity === true, 'historical-ambiguity-not-acknowledged');
  insist(index?.format === INDEX_FORMAT && hash(index) === options.approvedIndexDigest && same(index.identity,adapter.identity), 'index-not-approved-or-runtime-changed');
  const maximum = index.scope?.maxCandidates;
  insist(Array.isArray(index.chunks) && index.chunks.length >= 1 && (maximum === null || (Number.isSafeInteger(maximum) && maximum >= 1)) && index.scope.ownerId === options.ownerId, 'invalid-index-scope');
  let lastId = null, inspected = 0, proposed = 0;
  // Verify every chunk's exact bytes/plan before the first mutation. Read again
  // at use time so a concurrent plan-file replacement cannot change the action.
  for (const chunk of index.chunks) {
    const p = await readChunk(chunk); validatePlan(p,adapter,chunk.planDigest);
    insist(p.scope.ownerId === index.scope.ownerId && p.inspected === chunk.inspected && p.entries.length === chunk.proposed, 'chunk-scope-mismatch');
    for (const e of p.entries) { insist(lastId === null || e.id > lastId, 'duplicate-or-unordered-index-asset'); lastId = e.id; }
    inspected += p.inspected; proposed += p.entries.length;
  }
  insist(Number.isSafeInteger(inspected) && Number.isSafeInteger(proposed) && inspected === index.inspected && proposed === index.proposed && (maximum === null || inspected <= maximum), 'index-count-mismatch');
  let completed = 0;
  for (const chunk of index.chunks) {
    const p = await readChunk(chunk);
    const journal = await openJournal(chunk);
    try { completed += (await apply(adapter,p,{approvedDigest:chunk.planDigest,acknowledgeHistoryAmbiguity:true},journal)).length; }
    finally { await journal.close(); }
  }
  return completed;
}

module.exports = { INDEX_FORMAT, planAll, applyAll, FORMAT, CAPTURE_TAGS, ZONE_TAGS, MOTION_TAGS, HISTORY_WARNING, Stop, insist, stable, hash, same, iso, beforeDates, revisions, initialReason, strictTags, verifySource, plan, apply, undo, reconcile, validatePlan, assertChangedOnlyDates };
