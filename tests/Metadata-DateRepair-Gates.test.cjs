'use strict';
// Independent source-level safety review. Synthetic data only.
const test = require('node:test');
const assert = require('node:assert/strict');
const { initialReason, strictTags, assertChangedOnlyDates, validatePlan, hash, FORMAT, HISTORY_WARNING } = require('../runtime/metadata-date-repair/core.cjs');
const ids = ['00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000005'];
function snapshot() {
  const stamp = '2024-01-01T03:00:00.000Z';
  return { asset: { id: ids[0], ownerId: ids[1], type: 'IMAGE', originalPath: 'synthetic.png', isEdited: false, isOffline: false, deletedAt: null, livePhotoVideoId: null, updateId: ids[2], fileCreatedAt: stamp, fileModifiedAt: stamp, localDateTime: stamp, updatedAt: '2026-10-05T06:00:00.123456Z' }, exif: { assetId: ids[0], updateId: ids[3], updatedAt: '2026-10-05T06:00:00.654321Z', dateTimeOriginal: stamp, timeZone: null, lockedProperties: [] }, sidecars: [], reverseLiveLinks: 0 };
}
test('normal PostgreSQL microsecond revisions must not exclude a millisecond capture date', () => {
  assert.equal(initialReason(snapshot()), null);
});
test('pending metadata edit locks always exclude', () => {
  for (const property of ['dateTimeOriginal', 'timeZone', 'description']) {
    const s = snapshot(); s.exif.lockedProperties = [property];
    assert.equal(initialReason(s), 'metadata-locks-or-unknown');
  }
});
test('bad and unsupported metadata can never stand in for absent capture metadata', () => {
  for (const tags of [{}, { SourceFile: 'synthetic.png' }, { SourceFile: 'synthetic.png', MIMEType: 'image/png', Warning: 'read problem' }, { SourceFile: 'synthetic.png', MIMEType: 'image/png', DateTimeOriginal: 'malformed' }, { SourceFile: 'synthetic.png', MIMEType: 'image/png', OffsetTimeOriginal: '+09:00' }, { SourceFile: 'synthetic.png', MIMEType: 'image/png', MotionPhoto: 1 }]) {
    assert.throws(() => strictTags(tags, 'synthetic.png', () => undefined));
  }
});
test('only local date/timezone and automatic revision fields may change', () => {
  const before = snapshot();
  const dates = { fileCreatedAt: before.asset.fileCreatedAt, dateTimeOriginal: before.exif.dateTimeOriginal, localDateTime: '2024-01-01T12:00:00.000Z', timeZone: 'Asia/Tokyo' };
  const after = structuredClone(before);
  after.asset.localDateTime = dates.localDateTime; after.exif.timeZone = dates.timeZone;
  after.asset.updateId = ids[4]; after.exif.updateId = ids[4];
  assert.doesNotThrow(() => assertChangedOnlyDates(before, after, dates));
  for (const [table, key, value] of [['asset', 'fileCreatedAt', dates.localDateTime], ['exif', 'dateTimeOriginal', dates.localDateTime], ['asset', 'originalPath', 'renamed.png'], ['exif', 'lockedProperties', ['dateTimeOriginal']]]) {
    const bad = structuredClone(after); bad[table][key] = value;
    assert.throws(() => assertChangedOnlyDates(before, bad, dates));
  }
});
test('plan digest/runtime/ownership tampering fails closed', () => {
  const s = snapshot();
  const adapter = { identity: { timezone: 'Asia/Tokyo', fingerprint: 'synthetic' } };
  const p = { format: FORMAT, historyWarning: HISTORY_WARNING, identity: adapter.identity, scope: { ownerId: ids[1], limit: 1 }, entries: [{ id: ids[0], snapshot: s, after: { fileCreatedAt: s.asset.fileCreatedAt, dateTimeOriginal: s.exif.dateTimeOriginal, localDateTime: '2024-01-01T12:00:00.000Z', timeZone: 'Asia/Tokyo' } }] };
  assert.doesNotThrow(() => validatePlan(p, adapter, hash(p)));
  assert.throws(() => validatePlan(p, adapter, '0'.repeat(64)));
  assert.throws(() => validatePlan(p, { identity: { ...adapter.identity, timezone: 'UTC' } }, hash(p)));
  const tampered = structuredClone(p); tampered.scope.ownerId = ids[4];
  assert.throws(() => validatePlan(tampered, adapter, hash(tampered)));
});
