'use strict';

// Synthetic I/O accounting only: import the real planner, never a server or database.
const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../runtime/metadata-date-repair/core.cjs');

const ID = n => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
const OWNER = ID(9000);
const INSTANT = '2024-05-01T03:04:05.678Z';
const LOCAL = '2024-05-01T12:04:05.678Z';
const OPTIONS = { ownerId: OWNER, limit: 1000, pageSize: 25 };

function snapshot(n) {
  return {
    asset: {
      id: ID(n), ownerId: OWNER, originalPath: `/synthetic/${n}.png`,
      fileCreatedAt: INSTANT, localDateTime: INSTANT, fileModifiedAt: INSTANT,
      updatedAt: '2026-10-05T06:00:00.123456Z', updateId: ID(1000 + n),
      isEdited: false, isOffline: false, isExternal: false, deletedAt: null,
      type: 'IMAGE', livePhotoVideoId: null,
    },
    exif: {
      assetId: ID(n), dateTimeOriginal: INSTANT, timeZone: null,
      lockedProperties: [], updatedAt: '2026-10-05T06:00:00.654321Z',
      updateId: ID(2000 + n),
    },
    sidecars: [], reverseLiveLinks: 0,
  };
}

function fixture(count) {
  const rows = new Map(Array.from({ length: count }, (_, i) => [ID(i + 1), snapshot(i + 1)]));
  const events = [], batches = [], pages = [];
  const counts = { metadata: 0, activeMetadata: 0, maxActiveMetadata: 0, snapshot: 0, writes: 0 };
  const statCalls = new Map(), sidecarCalls = new Map();
  const adapter = {
    identity: { upstreamCommit: 'synthetic', timezone: 'Asia/Tokyo' },
    rows, events, batches, pages, counts,
    async candidates(options) {
      pages.push(structuredClone(options));
      events.push({ kind: 'page' });
      return [...rows.values()]
        .filter(s => s.asset.ownerId === options.ownerId && (!options.afterId || s.asset.id > options.afterId))
        .slice(0, options.limit).map(s => structuredClone(s));
    },
    async snapshots(ids) {
      assert(ids.length > 0 && ids.length <= 100, 'snapshot batch must be nonempty and bounded');
      assert.equal(new Set(ids).size, ids.length, 'snapshot IDs must be unique');
      batches.push([...ids]);
      events.push({ kind: 'snapshots', ids: [...ids] });
      return ids.flatMap(id => rows.has(id) ? [structuredClone(rows.get(id))] : []);
    },
    async snapshot() {
      counts.snapshot++;
      throw new Error('planner must not fall back to per-candidate snapshot reads');
    },
    async stat(source) {
      const call = (statCalls.get(source) || 0) + 1;
      statCalls.set(source, call);
      events.push({ kind: 'stat', source, call });
      const result = {
        token: { size: '42', mtimeNs: '1', ctimeNs: '2', birthtimeNs: '3', ino: '4' },
        stats: { birthtimeMs: Date.parse(INSTANT), mtimeMs: Date.parse(INSTANT) + 1000, mtime: new Date(Date.parse(INSTANT) + 1000) },
      };
      adapter.changeStat?.(result, source, call);
      return result;
    },
    async sidecarsAbsent(source) {
      const call = (sidecarCalls.get(source) || 0) + 1;
      sidecarCalls.set(source, call);
      events.push({ kind: 'sidecar', source, call });
      return adapter.hasSidecar ? !adapter.hasSidecar(source, call) : true;
    },
    async readMetadata(source) {
      counts.metadata++;
      counts.activeMetadata++;
      counts.maxActiveMetadata = Math.max(counts.maxActiveMetadata, counts.activeMetadata);
      events.push({ kind: 'metadata-start', source });
      try {
        // Yield so a concurrent implementation cannot accidentally pass the sequential-I/O assertion.
        await new Promise(resolve => setImmediate(resolve));
        const result = { canonicalSourcePath: source, tags: { SourceFile: source, MIMEType: 'image/png' } };
        await adapter.changeMetadata?.(result, source);
        return result;
      } finally {
        counts.activeMetadata--;
        events.push({ kind: 'metadata-end', source });
      }
    },
    firstDateTime: () => undefined,
    getDates: () => ({ dateTimeOriginal: INSTANT, localDateTime: LOCAL, timeZone: 'Asia/Tokyo' }),
    metadataEvidence: tags => ({ MIMEType: tags.MIMEType }),
    async transaction() {
      counts.writes++;
      throw new Error('planning must not begin a write transaction');
    },
  };
  return adapter;
}

function assertReadOnly(adapter, expectedRows) {
  assert.equal(adapter.counts.writes, 0);
  assert.equal(adapter.counts.snapshot, 0);
  assert.equal(adapter.counts.activeMetadata, 0);
  if (expectedRows) assert.deepEqual(adapter.rows, expectedRows);
}

for (const count of [1, 25, 26, 63]) {
  test(`${count} candidates use ceil(N / 25) page snapshot batches after sequential metadata reads`, async () => {
    const adapter = fixture(count), before = structuredClone(adapter.rows);
    const result = await core.plan(adapter, OPTIONS);
    assert.equal(result.entries.length, count);
    assert.equal(result.inspected, count);
    assert.equal(result.exhausted, true);
    assert.equal(adapter.batches.length, Math.ceil(count / 25));
    assert.deepEqual(adapter.batches.map(ids => ids.length),
      Array.from({ length: Math.ceil(count / 25) }, (_, i) => Math.min(25, count - i * 25)));
    assert.deepEqual(adapter.batches.flat(), Array.from({ length: count }, (_, i) => ID(i + 1)));
    assert.equal(adapter.counts.metadata, count);
    assert.equal(adapter.counts.maxActiveMetadata, 1);
    assert.equal(adapter.events.filter(event => event.kind === 'stat').length, 2 * count);
    assert.equal(adapter.events.filter(event => event.kind === 'sidecar').length, 2 * count);
    let pageMetadata = [];
    for (const event of adapter.events) {
      if (event.kind === 'page') assert.deepEqual(pageMetadata, [], 'previous page must finish its batch before the next page');
      if (event.kind === 'metadata-end') pageMetadata.push(event.source);
      if (event.kind === 'snapshots') {
        assert.deepEqual(pageMetadata, event.ids.map(id => before.get(id).asset.originalPath));
        pageMetadata = [];
      }
    }
    assert.deepEqual(pageMetadata, []);
    assertReadOnly(adapter, before);
  });
}

for (const gate of ['initial eligibility', 'source metadata']) {
  test(`an entire page excluded by ${gate} requires no snapshot API`, async () => {
    const adapter = fixture(25);
    if (gate === 'initial eligibility') {
      for (const row of adapter.rows.values()) row.exif.timeZone = 'UTC';
    } else {
      adapter.changeMetadata = result => { result.tags.Warning = 'synthetic warning'; };
    }
    delete adapter.snapshots;
    const before = structuredClone(adapter.rows), result = await core.plan(adapter, OPTIONS);
    assert.equal(result.entries.length, 0);
    assert.equal(result.excluded.length, 25);
    assert.equal(adapter.batches.length, 0);
    assert.equal(adapter.counts.metadata, gate === 'initial eligibility' ? 0 : 25);
    assertReadOnly(adapter, before);
  });
}

test('a mixed page batches only source-verified candidate IDs', async () => {
  const adapter = fixture(4);
  adapter.rows.get(ID(2)).exif.timeZone = 'UTC';
  adapter.changeMetadata = (result, source) => {
    if (source === '/synthetic/3.png') result.tags.Warning = 'synthetic warning';
  };
  const before = structuredClone(adapter.rows), result = await core.plan(adapter, OPTIONS);
  assert.deepEqual(adapter.batches, [[ID(1), ID(4)]]);
  assert.deepEqual(result.entries.map(entry => entry.id), [ID(1), ID(4)]);
  assert.deepEqual(result.excluded, [
    { id: ID(2), reason: 'existing-timezone' },
    { id: ID(3), reason: 'metadata-warning' },
  ]);
  assertReadOnly(adapter, before);
});

test('missing batch support fails closed without a per-candidate fallback', async () => {
  const adapter = fixture(2), before = structuredClone(adapter.rows);
  delete adapter.snapshots;
  await assert.rejects(() => core.plan(adapter, OPTIONS), error => error.code === 'batch-snapshots-required');
  assertReadOnly(adapter, before);
});

test('a failed batch read propagates without retrying individual snapshots', async () => {
  const adapter = fixture(2), before = structuredClone(adapter.rows);
  const failure = new Error('synthetic batch read failed');
  let batchCalls = 0;
  adapter.snapshots = async () => { batchCalls++; throw failure; };
  await assert.rejects(() => core.plan(adapter, OPTIONS), error => error === failure);
  assert.equal(batchCalls, 1);
  assertReadOnly(adapter, before);
});

for (const [name, change] of [
  ['revision', row => { row.asset.updateId = ID(8000); }],
  ['date value without a revision change', row => { row.asset.localDateTime = LOCAL; }],
  ['linked sidecar without a revision change', row => { row.sidecars.push({ path: '/synthetic/1.xmp' }); }],
]) {
  test(`page revalidation excludes an earlier row whose ${name} changes during later metadata I/O`, async () => {
    const adapter = fixture(2);
    adapter.changeMetadata = (_result, source) => {
      if (source === '/synthetic/2.png') change(adapter.rows.get(ID(1)));
    };
    const result = await core.plan(adapter, OPTIONS);
    assert.deepEqual(adapter.batches, [[ID(1), ID(2)]]);
    assert.deepEqual(result.entries.map(entry => entry.id), [ID(2)]);
    assert.deepEqual(result.excluded, [{ id: ID(1), reason: 'snapshot-changed-during-plan' }]);
    assertReadOnly(adapter);
  });
}

test('batch results are matched by ID, and a row removed during metadata I/O is excluded', async () => {
  const adapter = fixture(3);
  adapter.changeMetadata = (_result, source) => {
    if (source === '/synthetic/3.png') adapter.rows.delete(ID(2));
  };
  const snapshots = adapter.snapshots;
  adapter.snapshots = async ids => (await snapshots(ids)).reverse();
  const result = await core.plan(adapter, OPTIONS);
  assert.deepEqual(result.entries.map(entry => entry.id), [ID(1), ID(3)]);
  assert.deepEqual(result.excluded, [{ id: ID(2), reason: 'snapshot-changed-during-plan' }]);
  assertReadOnly(adapter);
});

for (const hasBirthtime of [true, false]) {
  test(`an unanchored first stat skips all metadata reads (${hasBirthtime ? 'birthtime available' : 'mtime fallback'})`, async () => {
    const adapter = fixture(1), before = structuredClone(adapter.rows);
    adapter.changeStat = result => {
      result.stats.birthtimeMs = hasBirthtime ? Date.parse(INSTANT) + 86400000 : 0;
      result.stats.mtimeMs = Date.parse(INSTANT) + 86401000;
      result.stats.mtime = new Date(result.stats.mtimeMs);
    };
    const result = await core.plan(adapter, OPTIONS);
    assert.deepEqual(result.excluded, [{ id: ID(1), reason: 'stored-instant-not-filesystem-anchored' }]);
    assert.equal(result.entries.length, 0);
    assert.equal(adapter.counts.metadata, 0);
    assert.equal(adapter.events.filter(event => event.kind === 'stat').length, 1);
    assert.equal(adapter.events.filter(event => event.kind === 'sidecar').length, 0);
    assert.equal(adapter.batches.length, 0);
    assertReadOnly(adapter, before);
  });
}

test('the initial sidecar guard still excludes an anchored source before metadata I/O', async () => {
  const adapter = fixture(1), before = structuredClone(adapter.rows);
  adapter.hasSidecar = () => true;
  const result = await core.plan(adapter, OPTIONS);
  assert.deepEqual(result.excluded, [{ id: ID(1), reason: 'sibling-sidecar' }]);
  assert.equal(adapter.counts.metadata, 0);
  assert.equal(adapter.batches.length, 0);
  assert.equal(adapter.events.filter(event => event.kind === 'sidecar').length, 1);
  assertReadOnly(adapter, before);
});

test('the final stat still rejects a source changed during metadata I/O', async () => {
  const adapter = fixture(1), before = structuredClone(adapter.rows);
  adapter.changeStat = (result, _source, call) => { if (call === 2) result.token.size = '43'; };
  const result = await core.plan(adapter, OPTIONS);
  assert.deepEqual(result.excluded, [{ id: ID(1), reason: 'source-changed-during-read' }]);
  assert.equal(adapter.counts.metadata, 1);
  assert.equal(adapter.events.filter(event => event.kind === 'stat').length, 2);
  assert.equal(adapter.batches.length, 0);
  assertReadOnly(adapter, before);
});

test('the final sidecar guard still rejects a sidecar created during metadata I/O', async () => {
  const adapter = fixture(1), before = structuredClone(adapter.rows);
  adapter.hasSidecar = (_source, call) => call === 2;
  const result = await core.plan(adapter, OPTIONS);
  assert.deepEqual(result.excluded, [{ id: ID(1), reason: 'sibling-sidecar' }]);
  assert.equal(adapter.counts.metadata, 1);
  assert.equal(adapter.events.filter(event => event.kind === 'sidecar').length, 2);
  assert.equal(adapter.batches.length, 0);
  assertReadOnly(adapter, before);
});

test('cancellation during metadata I/O performs no batch recheck or writes', async () => {
  const adapter = fixture(26), before = structuredClone(adapter.rows);
  const cancelled = new Error('synthetic cancellation');
  cancelled.name = 'AbortError';
  adapter.changeMetadata = () => { throw cancelled; };
  await assert.rejects(() => core.plan(adapter, OPTIONS), error => error === cancelled);
  assert.equal(adapter.counts.metadata, 1);
  assert.equal(adapter.batches.length, 0);
  assertReadOnly(adapter, before);
});

test('cancellation at a completed page does not read the next page or write anything', async () => {
  const adapter = fixture(26), before = structuredClone(adapter.rows);
  const cancelled = new Error('synthetic cancellation');
  const progress = [];
  await assert.rejects(() => core.plan(adapter, {
    ...OPTIONS,
    onProgress(value) { progress.push(value); throw cancelled; },
  }), error => error === cancelled);
  assert.deepEqual(progress, [{ inspected: 25, proposed: 25 }]);
  assert.equal(adapter.pages.length, 1);
  assert.equal(adapter.counts.metadata, 25);
  assert.equal(adapter.batches.length, 1);
  assertReadOnly(adapter, before);
});

// Generate each keyset page directly: these large-library tests never allocate,
// filter, or sort the whole library, and must never open an original file.
function generatedIneligibleLibrary(count) {
  const state = { queries: 0, returned: 0, originalReads: 0, lastId: null, lastSize: null };
  const forbidden = async () => { state.originalReads++; throw new Error('DB-ineligible rows must not read originals or snapshots'); };
  return {
    identity: { upstreamCommit: 'synthetic-uncapped', timezone: 'Asia/Tokyo' },
    state,
    async candidates(options) {
      assert.equal(options.ownerId, OWNER);
      assert(Number.isInteger(options.limit) && options.limit >= 1 && options.limit <= 25);
      assert.equal(options.afterId || null, state.lastId, 'keyset cursor must neither repeat nor skip a row');
      const after = options.afterId ? Number(options.afterId.slice(-12)) : 0;
      const length = Math.min(options.limit, Math.max(0, count - after));
      const rows = Array.from({ length }, (_, offset) => {
        const row = snapshot(after + offset + 1);
        row.exif.timeZone = 'UTC';
        return row;
      });
      state.queries++;
      state.returned += rows.length;
      state.lastSize = rows.length;
      if (rows.length) state.lastId = rows.at(-1).asset.id;
      return rows;
    },
    stat: forbidden, sidecarsAbsent: forbidden, readMetadata: forbidden,
    snapshots: forbidden, snapshot: forbidden, transaction: forbidden,
  };
}

for (const count of [0, 25, 1000, 100000, 100001]) {
  test(`uncapped plan-all exhausts ${count} generated candidates with bounded pages and chunks`, async () => {
    const adapter = generatedIneligibleLibrary(count);
    let stored = 0, storedCandidates = 0;
    const options = { ownerId: OWNER, pageSize: 25 };
    // Both omitted and explicit null represent the unlimited default.
    if (count === 100001) options.maxCandidates = null;
    const index = await core.planAll(adapter, options, async (plan, number) => {
      assert.equal(number, ++stored);
      assert.equal(plan.format, core.FORMAT);
      assert(plan.inspected >= 0 && plan.inspected <= 1000);
      assert(plan.scope.limit <= 1000);
      assert.equal(plan.entries.length, 0);
      assert.equal(plan.excluded.length, plan.inspected);
      for (const excluded of plan.excluded) {
        assert.equal(excluded.id, ID(++storedCandidates), 'saved IDs must be unique, consecutive, and complete');
        assert.equal(excluded.reason, 'existing-timezone');
      }
      return { file: `generated-${number}.json`, sha256: core.hash(plan) };
    });
    assert.equal(index.inspected, count);
    assert.equal(index.proposed, 0);
    assert.equal(index.exhausted, true);
    assert.equal(index.nextAfterId, null);
    assert.equal(storedCandidates, count);
    assert.equal(adapter.state.returned, count);
    assert.equal(adapter.state.queries, Math.floor(count / 25) + 1, 'continue until an empty or partial page proves exhaustion');
    assert.equal(adapter.state.lastSize, count % 25);
    assert.equal(adapter.state.originalReads, 0);
    assert.equal(index.chunks.length, stored);
    assert.equal(stored, Math.max(1, Math.ceil(count / 1000)), 'an empty terminal page must not create a redundant saved chunk');
    if (count === 100001) assert.equal(stored, 101, 'the former 100-chunk ceiling must not truncate the library');
  });
}

for (const count of [25, 26]) {
  test(`uncapped planner explicit advanced bound uses DB-only lookahead for ${count} candidates`, async () => {
    const adapter = generatedIneligibleLibrary(count);
    const index = await core.planAll(adapter, { ownerId: OWNER, pageSize: 25, maxCandidates: 25 }, async (plan, n) => {
      assert.equal(plan.inspected, 25);
      return { file: `bounded-${n}.json`, sha256: core.hash(plan) };
    });
    assert.equal(index.inspected, 25);
    assert.equal(index.exhausted, count === 25);
    assert.equal(index.nextAfterId, count === 25 ? null : ID(25));
    assert.equal(adapter.state.queries, 2);
    assert.equal(adapter.state.originalReads, 0);
  });
}

function generatedEmptyChunkIndex(adapter, count) {
  const plans = new Map();
  const index = {
    format: core.INDEX_FORMAT, createdAt: INSTANT, identity: structuredClone(adapter.identity),
    historyWarning: core.HISTORY_WARNING,
    scope: { ownerId: OWNER, maxCandidates: null, chunkSize: 1000 },
    inspected: count, proposed: 0, exhausted: true, nextAfterId: null, chunks: [],
  };
  for (let n = 1; n <= count; n++) {
    const plan = {
      format: core.FORMAT, createdAt: INSTANT, identity: structuredClone(adapter.identity),
      historyWarning: core.HISTORY_WARNING,
      scope: { ownerId: OWNER, limit: 1000, pageSize: 25, afterId: n === 1 ? null : ID(n - 1) },
      inspected: 1, nextAfterId: n === count ? null : ID(n), exhausted: n === count,
      entries: [], excluded: [{ id: ID(n), reason: 'existing-timezone' }],
    };
    const file = `empty-${n}.json`;
    plans.set(file, plan);
    index.chunks.push({ file, sha256: core.hash(plan), planDigest: core.hash(plan), inspected: 1, proposed: 0 });
  }
  return { index, plans };
}

test('uncapped apply-all accepts 101 valid chunks and preflights every digest before opening journals', async () => {
  const adapter = generatedIneligibleLibrary(0);
  const { index, plans } = generatedEmptyChunkIndex(adapter, 101);
  let reads = 0, opened = 0, headers = 0, completed = 0, closed = 0;
  const applied = await core.applyAll(adapter, index, {
    ownerId: OWNER, approvedIndexDigest: core.hash(index), acknowledgeHistoryAmbiguity: true,
  }, async chunk => { reads++; return structuredClone(plans.get(chunk.file)); }, async () => {
    assert(reads >= 102, 'all 101 plan digests must be checked before the first journal opens');
    opened++;
    return {
      async header(value) { assert.equal(value.format, core.FORMAT); headers++; },
      async appendSync(value) { assert.deepEqual(value, { kind: 'complete', count: 0 }); completed++; },
      async close() { closed++; },
    };
  });
  assert.equal(applied, 0);
  assert.equal(reads, 202);
  assert.deepEqual([opened, headers, completed, closed], [101, 101, 101, 101]);
  assert.equal(adapter.state.originalReads, 0);
});

test('uncapped apply-all rejects a changed last chunk before any journal or original read', async () => {
  const adapter = generatedIneligibleLibrary(0);
  const { index, plans } = generatedEmptyChunkIndex(adapter, 101);
  plans.get('empty-101.json').createdAt = '2025-01-01T00:00:00.000Z';
  let opened = 0;
  await assert.rejects(() => core.applyAll(adapter, index, {
    ownerId: OWNER, approvedIndexDigest: core.hash(index), acknowledgeHistoryAmbiguity: true,
  }, async chunk => plans.get(chunk.file), async () => { opened++; throw new Error('must not open a journal'); }),
  error => error.code === 'plan-digest-not-approved');
  assert.equal(opened, 0);
  assert.equal(adapter.state.originalReads, 0);
});

for (const order of ['duplicate', 'descending']) {
  test(`uncapped apply-all rejects ${order} cross-chunk asset IDs before journals`, async () => {
    const adapter = fixture(2);
    const source = await core.plan(adapter, OPTIONS);
    const { index, plans } = generatedEmptyChunkIndex(adapter, 2);
    index.proposed = 2;
    const selected = order === 'duplicate' ? [source.entries[0], source.entries[0]] : [...source.entries].reverse();
    for (let i = 0; i < 2; i++) {
      const chunk = index.chunks[i], plan = plans.get(chunk.file);
      plan.entries = [structuredClone(selected[i])];
      plan.excluded = [];
      chunk.proposed = 1;
      chunk.planDigest = core.hash(plan);
      chunk.sha256 = core.hash(plan);
    }
    let opened = 0;
    await assert.rejects(() => core.applyAll(adapter, index, {
      ownerId: OWNER, approvedIndexDigest: core.hash(index), acknowledgeHistoryAmbiguity: true,
    }, async chunk => plans.get(chunk.file), async () => { opened++; throw new Error('must not open a journal'); }),
    error => error.code === 'duplicate-or-unordered-index-asset');
    assert.equal(opened, 0);
    assertReadOnly(adapter);
  });
}
