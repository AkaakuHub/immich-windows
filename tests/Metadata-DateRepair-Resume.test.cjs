'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const core = require('../runtime/metadata-date-repair/core.cjs');
const { prepareResume, readResumeChunk, isCompatiblePlanIdentity, KNOWN_TOOL_HASHES } = require('../runtime/metadata-date-repair/resume.cjs');
const ID = n => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
const OWNER = ID(900);
const current = () => ({ upstreamCommit: 'upstream-test', version: '2.5.6', node: 'v22.18.0', platform: 'win32', timezone: 'Asia/Tokyo', files: { 'metadata.service.js': '1'.repeat(64) }, database: { name: 'immich', address: '127.0.0.1', port: 5432 }, schemaDigest: '2'.repeat(64), triggersDigest: '3'.repeat(64), toolHashes: Object.fromEntries(['core.cjs', 'runtime.cjs', 'cli.cjs', 'guided.cjs', 'resume.cjs'].map((file, i) => [file, String(i + 4).repeat(64)])) });
const adapter = () => new Proxy({ identity: current() }, { get(target, key) { assert.equal(key, 'identity', 'resume must not access photos, candidates, or write methods'); return target[key]; } });
const partName = n => 'plan.json.part-' + String(n).padStart(4, '0') + '.json';
function plan({ start = 1, count = 2, after = null, exhausted = false, hashes = KNOWN_TOOL_HASHES[0] } = {}) {
  return { format: core.FORMAT, createdAt: '2026-10-05T00:00:00.000Z', identity: { ...current(), toolHashes: { ...hashes } }, historyWarning: core.HISTORY_WARNING, scope: { ownerId: OWNER, limit: Math.max(count, 1), pageSize: 2, afterId: after }, inspected: count, entries: [], excluded: Array.from({ length: count }, (_, i) => ({ id: ID(start + i), reason: 'existing-timezone' })), exhausted, nextAfterId: exhausted ? null : ID(start + count - 1) };
}
async function fixture(fn) { const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'date-repair-resume-')); try { await fn(directory); } finally { await fs.rm(directory, { recursive: true, force: true }); } }
async function write(directory, number, p) { const file = partName(number); const text = JSON.stringify(p, null, 2) + '\n'; await fs.writeFile(path.join(directory, file), text); return { file, sha256: createHash('sha256').update(text).digest('hex'), planDigest: core.hash(p), inspected: p.inspected, proposed: p.entries.length }; }
async function rejects(directory, code, extra = {}) { await assert.rejects(() => prepareResume({ directory, adapter: adapter(), ownerId: OWNER, ...extra }), error => !code || error.code === code); }

test('known LF producer resumes immutable contiguous parts without media reads or database writes', async () => fixture(async directory => {
  await fs.writeFile(path.join(directory, 'plan.json'), '');
  const original = plan();
  const first = await write(directory, 1, original);
  await write(directory, 2, plan({ start: 3, count: 1, after: ID(2), exhausted: true }));
  const before = await fs.readFile(path.join(directory, first.file));
  const index = await prepareResume({ directory, adapter: adapter(), ownerId: OWNER });
  assert.equal(index.format, core.INDEX_FORMAT); assert.deepEqual(index.identity, current());
  assert.deepEqual(index.scope, { ownerId: OWNER, maxCandidates: null, chunkSize: 1000 });
  assert.equal(index.inspected, 3); assert.equal(index.proposed, 0); assert.equal(index.exhausted, true); assert.equal(index.nextAfterId, null);
  assert.deepEqual(index.chunks[0], { ...first, sourceDirectory: directory });
  assert.deepEqual(await fs.readFile(path.join(directory, first.file)), before);
  assert.deepEqual(await readResumeChunk(index.chunks[0], { directory }), original);
}));

test('exact CRLF producer and exact current producer are accepted, mixed or unknown tuples refused', () => {
  for (const hashes of [...KNOWN_TOOL_HASHES, current().toolHashes]) assert.equal(isCompatiblePlanIdentity({ ...current(), toolHashes: hashes }, current()), true);
  const mixed = { ...KNOWN_TOOL_HASHES[0], 'core.cjs': KNOWN_TOOL_HASHES[1]['core.cjs'] };
  assert.equal(isCompatiblePlanIdentity({ ...current(), toolHashes: mixed }, current()), false);
  assert.equal(isCompatiblePlanIdentity({ ...current(), toolHashes: { ...KNOWN_TOOL_HASHES[0], evil: '4'.repeat(64) } }, current()), false);
  assert.equal(isCompatiblePlanIdentity({}, {}), false);
});
for (const field of ['upstreamCommit', 'version', 'node', 'platform', 'timezone', 'files', 'database', 'schemaDigest', 'triggersDigest']) test(`resume refuses ${field} mismatch without writing files`, async () => fixture(async directory => {
  const p = plan(); p.identity[field] = typeof p.identity[field] === 'object' ? {} : 'changed'; await write(directory, 1, p);
  await rejects(directory, 'resume-runtime-or-timezone-changed'); assert.deepEqual(await fs.readdir(directory), [partName(1)]);
}));
test('owner mismatch and unknown producer fail closed', async () => fixture(async directory => {
  const p = plan(); p.scope.ownerId = ID(901); await write(directory, 1, p); await rejects(directory, 'resume-owner-or-cursor-mismatch');
  p.scope.ownerId = OWNER; p.identity.toolHashes['core.cjs'] = '0'.repeat(64); await write(directory, 1, p); await rejects(directory, 'resume-runtime-or-timezone-changed');
}));
test('a missing chunk, malformed tail, and malformed part name are not skipped for an empty old index', async () => fixture(async directory => {
  await fs.writeFile(path.join(directory, 'plan.json'), ''); await write(directory, 1, plan()); await write(directory, 3, plan({ start: 3, after: ID(2) }));
  await rejects(directory, 'resume-chunk-gap'); await fs.rename(path.join(directory, partName(3)), path.join(directory, partName(2)));
  await fs.writeFile(path.join(directory, partName(2)), '{"format":'); await rejects(directory, 'invalid-resume-json');
  await fs.rm(path.join(directory, partName(2))); await fs.writeFile(path.join(directory, 'plan.json.part-0002.json.tmp'), '{}'); await rejects(directory, 'invalid-resume-chunk-path');
}));
test('an empty index with no complete parts is not approval; other folders are not searched', async () => fixture(async directory => {
  await fs.writeFile(path.join(directory, 'plan.json'), ''); await fs.mkdir(path.join(directory, 'nested')); await write(path.join(directory, 'nested'), 1, plan());
  await rejects(directory, 'no-complete-resume-chunks');
}));
test('unknown nonempty index does not fall back to local parts', async () => fixture(async directory => {
  await write(directory, 1, plan()); await fs.writeFile(path.join(directory, 'plan.json'), '{"partial":'); await rejects(directory, 'invalid-resume-json');
}));
test('duplicate excluded IDs and excluded cursor mismatches are rejected', async () => fixture(async directory => {
  const p = plan(); p.excluded[1].id = p.excluded[0].id; await write(directory, 1, p); await rejects(directory, 'invalid-resume-keyset');
  await write(directory, 1, plan()); const next = plan({ start: 3, after: ID(1) }); await write(directory, 2, next); await rejects(directory, 'resume-owner-or-cursor-mismatch');
  next.scope.afterId = ID(2); next.excluded[0].id = ID(2); await write(directory, 2, next); await rejects(directory, 'invalid-resume-keyset');
}));
test('legitimate out-of-order exclusion arrays retain the union cursor', async () => fixture(async directory => {
  const p = plan(); p.excluded.reverse(); await write(directory, 1, p); const index = await prepareResume({ directory, adapter: adapter(), ownerId: OWNER }); assert.equal(index.nextAfterId, ID(2));
}));
for (const change of [p => p.inspected++, p => p.scope.limit = 1001, p => p.scope.pageSize = 101, p => p.nextAfterId = ID(3), p => p.exhausted = 'false', p => p.scope.limit++]) test('malformed count, scope, or continuation refuses the whole prefix', async () => fixture(async directory => {
  const p = plan(); change(p); await write(directory, 1, p); await rejects(directory);
}));
test('a chunk after exhausted is refused', async () => fixture(async directory => {
  await write(directory, 1, plan({ exhausted: true })); await write(directory, 2, plan({ start: 3, after: ID(2) })); await rejects(directory, 'resume-chunk-after-exhaustion');
}));
test('symlink file and strict directory-prefix escapes are refused', async () => fixture(async directory => {
  const other = directory + '-other'; await fs.mkdir(other); try {
    await write(other, 1, plan()); await fs.symlink(path.join(other, partName(1)), path.join(directory, partName(1))); await rejects(directory, 'unsafe-resume-file');
    await fs.rm(path.join(directory, partName(1))); await fs.symlink(other, path.join(directory, 'link')); await rejects(path.join(directory, 'link'), 'unsafe-resume-directory');
    await assert.rejects(() => readResumeChunk({ file: '../' + partName(1), sha256: '0'.repeat(64), planDigest: '0'.repeat(64) }, { directory }), e => e.code === 'invalid-resume-chunk-path');
  } finally { await fs.rm(other, { recursive: true, force: true }); }
}));
test('source bytes changing between validation and reread are refused', async () => fixture(async directory => {
  await write(directory, 1, plan()); const open = fs.open; let reads = 0;
  fs.open = async function(file, ...args) { if (file === path.join(directory, partName(1)) && ++reads === 2) await fs.appendFile(file, ' '); return open.call(this, file, ...args); };
  try { await rejects(directory); assert.equal(reads, 2); } finally { fs.open = open; }
}));
test('resume honors explicit maximum and refuses one below completed progress', async () => fixture(async directory => {
  await write(directory, 1, plan()); await rejects(directory, 'resume-total-bound-exceeded', { maximum: 1 });
  const index = await prepareResume({ directory, adapter: adapter(), ownerId: OWNER, maximum: 3 }); assert.equal(index.scope.maxCandidates, 3);
}));
test('checkpoint directly references immutable old parts and ignores uncheckpointed local tail', async () => fixture(async directory => {
  const old = path.join(directory, 'old'), checkpointDir = path.join(directory, 'checkpoint'); await fs.mkdir(old); await fs.mkdir(checkpointDir);
  await write(old, 1, plan()); const index = await prepareResume({ directory: old, adapter: adapter(), ownerId: OWNER });
  await fs.writeFile(path.join(checkpointDir, 'plan.json'), JSON.stringify(index));
  await fs.writeFile(path.join(checkpointDir, partName(2)), '{unfinished');
  const resumed = await prepareResume({ directory: checkpointDir, adapter: adapter(), ownerId: OWNER });
  assert.equal(resumed.chunks.length, 1); assert.equal(resumed.nextAfterId, ID(2)); assert.equal(resumed.chunks[0].sourceDirectory, old);
  index.chunks[0].sha256 = '0'.repeat(64); await fs.writeFile(path.join(checkpointDir, 'plan.json'), JSON.stringify(index)); await rejects(checkpointDir, 'resume-index-chunk-mismatch');
}));
test('oversize part is refused before reading payload', async () => fixture(async directory => {
  const handle = await fs.open(path.join(directory, partName(1)), 'w'); try { await handle.truncate(16 * 1024 * 1024 + 1); } finally { await handle.close(); }
  await rejects(directory, 'unsafe-resume-file');
}));

test('eligible entries are preserved verbatim and contribute to resumed proposal counts', async () => fixture(async directory => {
  const instant = '2024-05-01T03:04:05.678Z';
  const snapshot = { asset: { id: ID(1), ownerId: OWNER, originalPath: '/synthetic/1.png', fileCreatedAt: instant, localDateTime: instant, fileModifiedAt: instant, updatedAt: instant, updateId: ID(101), isEdited: false, isOffline: false, deletedAt: null, type: 'IMAGE', livePhotoVideoId: null }, exif: { assetId: ID(1), dateTimeOriginal: instant, timeZone: null, lockedProperties: [], updatedAt: instant, updateId: ID(201) }, sidecars: [], reverseLiveLinks: 0 };
  const p = plan(); p.excluded.shift(); p.entries.push({ id: ID(1), snapshot, stat: { size: '42' }, metadataDigest: '9'.repeat(64), after: { fileCreatedAt: instant, localDateTime: '2024-05-01T12:04:05.678Z', dateTimeOriginal: instant, timeZone: 'Asia/Tokyo' } });
  await write(directory, 1, p); const index = await prepareResume({ directory, adapter: adapter(), ownerId: OWNER });
  assert.equal(index.proposed, 1); assert.equal(index.chunks[0].proposed, 1); assert.deepEqual(await readResumeChunk(index.chunks[0], { directory }), p);
  p.excluded[0].id = ID(1); await write(directory, 1, p); await rejects(directory, 'invalid-resume-keyset');
}));

test('resumed planning starts after the last inspected UUID and does not reread prior assets', async () => fixture(async directory => {
  await write(directory, 1, plan()); const seed = await prepareResume({ directory, adapter: adapter(), ownerId: OWNER });
  const calls = [], chunks = [];
  const a = { identity: current(), async candidates(options) { calls.push(options); assert(options.afterId >= ID(2)); return [3, 4, 5].filter(n => ID(n) > options.afterId).slice(0, options.limit).map(n => ({ asset: { id: ID(n), ownerId: OWNER }, exif: {} })); } };
  const result = await core.planAll(a, { ownerId: OWNER, maxCandidates: null, pageSize: 2 }, async (p, n) => { chunks.push({ p, n }); return { file: partName(n), sha256: 'a'.repeat(64) }; }, seed);
  assert.equal(calls[0].afterId, ID(2)); assert.equal(result.inspected, 5); assert.equal(result.exhausted, true); assert.equal(chunks.length, 1); assert.equal(chunks[0].n, 2); assert.equal(chunks[0].p.scope.afterId, ID(2));
}));

test('case variants cannot disguise duplicate UUIDs', async () => fixture(async directory => {
  const p = plan(); p.excluded[0].id = '00000000-0000-4000-8000-00000000000a'; p.excluded[1].id = '00000000-0000-4000-8000-00000000000A'; p.nextAfterId = p.excluded[0].id;
  await write(directory, 1, p); await rejects(directory, 'invalid-resume-keyset');
}));

test('terminal index-only zero-row probe is repeated from the last full part cursor', async () => fixture(async directory => {
  const first = await write(directory, 1, plan());
  const checkpoint = await prepareResume({ directory, adapter: adapter(), ownerId: OWNER }); checkpoint.exhausted = true; checkpoint.nextAfterId = null;
  await fs.writeFile(path.join(directory, 'plan.json'), JSON.stringify(checkpoint));
  const seed = await prepareResume({ directory, adapter: adapter(), ownerId: OWNER });
  assert.equal(seed.exhausted, false); assert.equal(seed.nextAfterId, ID(2)); assert.equal(seed.chunks[0].planDigest, first.planDigest);
  let probes = 0;
  const a = { identity: current(), async candidates(options) { probes++; assert.equal(options.afterId, ID(2)); return []; } };
  const result = await core.planAll(a, { ownerId: OWNER, maxCandidates: null, pageSize: 2 }, async () => { assert.fail('terminal probe does not copy or write a new part'); }, seed);
  assert.equal(probes, 1); assert.equal(result.exhausted, true); assert.equal(result.chunks.length, 1); assert.equal(result.nextAfterId, null);
  assert.deepEqual(await readResumeChunk(first, { directory }), plan());
}));

test('network and device resume paths are rejected before any filesystem access', async () => {
  const original = fs.lstat; let calls = 0;
  fs.lstat = async () => { calls++; throw new Error('filesystem must not be reached'); };
  try {
    for (const directory of [String.raw`\\server\share`, String.raw`\\?\C:\private`, String.raw`\\.\C:\private`, '//server/share']) {
      await assert.rejects(prepareResume({ directory, adapter: adapter(), ownerId: OWNER }), error => error.code === 'resume-local-directory-required');
    }
  } finally { fs.lstat = original; }
  assert.equal(calls, 0);
});
