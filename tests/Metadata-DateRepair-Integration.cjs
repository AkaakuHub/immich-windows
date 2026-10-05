'use strict';
// This test is deliberately restricted to the existing disposable Windows CI
// installation. No production env or user photos; only a tiny generated PNG.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID, randomBytes, createHash } = require('node:crypto');
const { createRequire } = require('node:module');

function arg(name) {
  const i = process.argv.indexOf(name);
  assert(i >= 0 && process.argv[i + 1], `Missing ${name}`);
  return process.argv[i + 1];
}
function inside(root, target) {
  const relative = path.relative(root, target);
  return relative && !relative.startsWith('..') && !path.isAbsolute(relative);
}
let stage = 'windows-ci-guards';
async function test() {
  assert.equal(process.platform, 'win32', 'Disposable Windows CI only');
  assert.equal(process.env.GITHUB_ACTIONS, 'true', 'GitHub Actions only');
  assert.equal(process.env.CI, 'true', 'Explicit CI environment required');
  assert.equal(process.env.IMMICH_METADATA_REPAIR_TEST_ONLY, '1', 'Explicit CI test opt-in required');
  assert(process.env.RUNNER_TEMP, 'RUNNER_TEMP required');
  stage = 'ci-path-and-password-guards';
  const temporary = await fs.realpath(process.env.RUNNER_TEMP);
  const releaseRoot = await fs.realpath(arg('--release-root'));
  const passwordFile = await fs.realpath(arg('--password-file'));
  assert(inside(temporary, releaseRoot), 'Release must be inside the disposable runner directory');
  assert(inside(temporary, passwordFile), 'Password fixture must be inside RUNNER_TEMP');
  assert.equal(path.basename(passwordFile), 'immich-postgres-password.txt');
  const password = await fs.readFile(passwordFile, 'utf8');
  assert(/^[0-9a-f]{32}$/i.test(password), 'Unexpected test password fixture');
  // Do not inherit a live connection string or alternate credential file.
  for (const name of Object.keys(process.env)) if (/^(DB_|PG)/.test(name)) delete process.env[name];
  Object.assign(process.env, { DB_HOSTNAME: '127.0.0.1', DB_PORT: '5432', DB_USERNAME: 'postgres', DB_PASSWORD: password, DB_DATABASE_NAME: 'immich_ci_allusers', TZ: 'Asia/Tokyo' });
  process.env.PATH = ['server/node_modules/@img/sharp-win32-x64/lib', 'runtime/vc-runtime', 'runtime/node', 'runtime/ffmpeg'].map(p => path.join(releaseRoot, p)).concat(process.env.PATH || '').join(path.delimiter);
  process.env.FFMPEG_PATH = path.join(releaseRoot, 'runtime/ffmpeg/ffmpeg.exe');
  process.env.FFPROBE_PATH = path.join(releaseRoot, 'runtime/ffmpeg/ffprobe.exe');

  stage = 'installed-module-import';
  const runtime = path.join(releaseRoot, 'runtime', 'metadata-date-repair');
  const core = require(path.join(runtime, 'core.cjs'));
  const { createAdapter } = require(path.join(runtime, 'runtime.cjs'));
  const { fileJournal, run } = require(path.join(runtime, 'cli.cjs'));
  const { runGuided } = require(path.join(runtime, 'guided.cjs'));
  const server = path.join(releaseRoot, 'server');
  const req = createRequire(path.join(server, 'package.json'));
  stage = 'installed-date-self-test';
  const synthetic = await createAdapter({ releaseRoot, connect: false });
  assert.equal(synthetic.identity.timezone, 'Asia/Tokyo');
  await synthetic.close();
  assert(!Object.keys(require.cache).some(file => /[\\/]server[\\/]dist[\\/](main|app\.module)\.js$/i.test(file)), 'Import must not load server bootstrap');

  const { Kysely, sql } = req('kysely');
  const { ConfigRepository } = req(path.join(server, 'dist/repositories/config.repository.js'));
  const { getKyselyConfig } = req(path.join(server, 'dist/utils/database.js'));
  const { ChecksumAlgorithm } = req(path.join(server, 'dist/enum.js'));
  const { log: _unsafeLog, ...config } = getKyselyConfig(new ConfigRepository().getEnv().database.config);
  const db = new Kysely({ ...config, log() {} });
  const ownerId = randomUUID(), clusterId = randomUUID(), assetId = randomUUID();
  let adapter, fixture, wroteFixture = false;
  const instant = '2024-01-15T03:04:05.000Z';
  const expectedLocal = '2024-01-15T12:04:05.000Z';
  const journals = [];
  const handles = [];
  const fullRows = async () => (await sql`select to_jsonb(a) as asset, to_jsonb(e) as exif from asset a join asset_exif e on e."assetId"=a.id where a.id=${assetId}::uuid and a."ownerId"=${ownerId}::uuid`.execute(db)).rows[0];
  const otherFields = (rows) => {
    const copy = structuredClone(rows);
    delete copy.asset.localDateTime; delete copy.exif.timeZone;
    for (const record of [copy.asset, copy.exif]) { delete record.updatedAt; delete record.updateId; }
    return copy;
  };
  const journal = (name, fail = false) => {
    let writer;
    async function append(record, header) {
      if (!writer) {
        const file = path.join(fixture, name + '.jsonl');
        const handle = await fs.open(file, 'wx', 0o600);
        handles.push(handle); journals.push(file); writer = fileJournal(handle);
      }
      if (fail && record.kind === 'prepared') throw new Error('synthetic-journal-failure');
      await (header ? writer.header(record) : writer.appendSync(record));
      if (record.kind === 'prepared') {
        // Separate connection still sees old committed dates after the real
        // journal fsync but before the adapter transaction callback returns.
        const visible = await fullRows();
        assert.equal(Date.parse(visible.asset.localDateTime), Date.parse(record.before.localDateTime));
        assert.equal(visible.exif.timeZone, record.before.timeZone);
      }
    }
    return {
      records: [],
      async header(record) { await append(record, true); this.records.push(structuredClone(record)); },
      async appendSync(record) { await append(record, false); this.records.push(structuredClone(record)); },
    };
  };
  try {
    stage = 'database-loopback-guard';
    const identity = (await sql`select current_database() as name, host(inet_server_addr()) as host`.execute(db)).rows[0];
    assert.equal(identity.name, 'immich_ci_allusers', 'Never write to another database');
    assert(['127.0.0.1', '::1'].includes(identity.host), 'Never write to a remote database');
    stage = 'fixture-setup';
    fixture = await fs.mkdtemp(path.join(temporary, 'immich-date-repair-ci-'));
    const originalPath = path.join(fixture, 'synthetic.png');
    // Generated 1x1 PNG fixture, unrelated to any user media.
    const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==', 'base64');
    await fs.writeFile(originalPath, png, { flag: 'wx' });
    await fs.utimes(originalPath, new Date(instant), new Date(instant));
    await db.transaction().execute(async tx => {
      await tx.insertInto('cluster_group').values({ id: clusterId, name: 'metadata-repair-ci' }).execute();
      await tx.insertInto('user').values({ id: ownerId, clusterGroupId: clusterId, email: `${ownerId}@metadata-repair.invalid`, name: 'Metadata repair CI fixture' }).execute();
      await tx.insertInto('asset').values({ id: assetId, ownerId, type: 'IMAGE', originalPath, originalFileName: 'synthetic.png', checksum: randomBytes(20), checksumAlgorithm: ChecksumAlgorithm.sha1File, fileCreatedAt: new Date(instant), fileModifiedAt: new Date(instant), localDateTime: new Date(instant) }).execute();
      await tx.insertInto('asset_exif').values({ assetId, dateTimeOriginal: new Date(instant), timeZone: null, lockedProperties: null }).execute();
    });
    wroteFixture = true;
    stage = 'installed-database-adapter';
    adapter = await createAdapter({ releaseRoot, ownerId });
    const initial = await adapter.snapshot(assetId);
    assert.deepEqual(await adapter.snapshots([assetId, randomUUID()]), [initial], 'Batch snapshot must return only existing assets in this owner scope');
    await assert.rejects(adapter.snapshots([assetId, assetId]), /invalid-snapshot-batch/);
    const initialFullRows = await fullRows();
    assert.equal(initial.asset.ownerId, ownerId);
    assert.deepEqual(initial.exif.lockedProperties, [], 'Normal SQL null locks mean no locks');
    assert.equal(core.initialReason(initial), null, 'Real trigger audit timestamps must be accepted');
    const proposed = { ...core.beforeDates(initial), localDateTime: expectedLocal, timeZone: 'Asia/Tokyo' };

    stage = 'transaction-rollback-checks';
    // Real Kysely SQL and real installed schema triggers; stale second-row CAS
    // must roll back the already-issued first-row UPDATE in the same transaction.
    await assert.rejects(adapter.transaction(async tx => {
      const row = await tx.snapshotForUpdate(assetId);
      row.exif.updateId = randomUUID();
      await tx.updateDates(row, proposed);
    }), /exif-cas-failed/);
    assert.deepEqual(await adapter.snapshot(assetId), initial, 'CAS failure must roll back both rows');
    await assert.rejects(adapter.transaction(async tx => {
      await tx.updateDates(await tx.snapshotForUpdate(assetId), proposed);
      throw new Error('synthetic-transaction-failure');
    }), /synthetic-transaction-failure/);
    assert.deepEqual(await adapter.snapshot(assetId), initial, 'Failed transaction must leave original revisions and dates');

    // Real ExifTool and filesystem evidence, with no decoder, original rewrite,
    // metadata extraction job, storage-template event, or workflow execution.
    stage = 'default-plan-check';
    const cliPlanFile = path.join(fixture, 'default-plan.json');
    await run(['--release-root', releaseRoot, '--owner-id', ownerId, '--expected-timezone', 'Asia/Tokyo', '--out', cliPlanFile, '--limit', '10', '--page-size', '10']);
    assert.equal(JSON.parse(await fs.readFile(cliPlanFile, 'utf8')).entries.length, 1, 'CLI without a command must produce a read-only plan');
    assert.deepEqual(await fullRows(), initialFullRows, 'Default CLI planning must not mutate database rows');
    stage = 'batch-plan-check';
    const batchIndexFile = path.join(fixture, 'batch-index.json');
    await run(['plan-all', '--release-root', releaseRoot, '--owner-id', ownerId, '--expected-timezone', 'Asia/Tokyo', '--out', batchIndexFile, '--max-candidates', '10', '--page-size', '10']);
    const batchIndex = JSON.parse(await fs.readFile(batchIndexFile, 'utf8'));
    assert.equal(batchIndex.proposed, 1);
    assert.equal(batchIndex.exhausted, true);
    assert.equal(batchIndex.chunks.length, 1);
    const chunkBytes = await fs.readFile(path.join(fixture, batchIndex.chunks[0].file));
    assert.equal(createHash('sha256').update(chunkBytes).digest('hex'), batchIndex.chunks[0].sha256);
    assert.equal(core.hash(JSON.parse(chunkBytes)), batchIndex.chunks[0].planDigest);
    assert.deepEqual(await fullRows(), initialFullRows, 'Whole-library planning must remain read-only');
    const plan = await core.plan(adapter, { ownerId, limit: 10, pageSize: 10 });
    assert.equal(plan.entries.length, 1, `Synthetic no-EXIF fixture did not qualify: ${JSON.stringify(plan.excluded)}`);
    assert.equal(plan.entries[0].id, assetId);
    assert.equal(plan.entries[0].after.localDateTime, expectedLocal);
    const approved = { approvedDigest: core.hash(plan), acknowledgeHistoryAmbiguity: true };
    await assert.rejects(core.apply(adapter, plan, approved, journal('failed', true)), /synthetic-journal-failure/);
    assert.deepEqual(await adapter.snapshot(assetId), initial, 'Journal failure before COMMIT must roll back both rows');

    stage = 'journal-apply-check';
    const appliedJournal = journal('apply');
    assert.deepEqual(await core.apply(adapter, plan, approved, appliedJournal), [assetId]);
    const applied = await adapter.snapshot(assetId);
    core.assertChangedOnlyDates(initial, applied, proposed);
    assert.deepEqual(otherFields(await fullRows()), otherFields(initialFullRows), 'All other database columns must remain unchanged');
    assert.equal(applied.asset.fileCreatedAt, instant);
    assert.equal(applied.exif.dateTimeOriginal, instant);
    assert.equal(applied.asset.localDateTime, expectedLocal);
    assert.equal(applied.exif.timeZone, 'Asia/Tokyo');
    assert.notEqual(applied.asset.updateId, initial.asset.updateId, 'Asset trigger must advance sync revision');
    assert.notEqual(applied.exif.updateId, initial.exif.updateId, 'EXIF trigger must advance sync revision');
    assert.deepEqual(await core.reconcile(adapter, appliedJournal.records), [{ id: assetId, state: 'applied-unchanged' }]);
    const again = await core.plan(adapter, { ownerId, limit: 10, pageSize: 10 });
    assert.equal(again.entries.length, 0, 'Already-repaired row must not gain another offset');
    await assert.rejects(core.apply(adapter, plan, approved, journal('stale')), /stale-plan/);

    stage = 'guarded-undo-check';
    const undoJournal = journal('undo');
    assert.deepEqual(await core.undo(adapter, plan, appliedJournal.records, { ...approved, approvedJournalDigest: core.hash(appliedJournal.records) }, undoJournal), [assetId]);
    const undone = await adapter.snapshot(assetId);
    assert.deepEqual(core.beforeDates(undone), core.beforeDates(initial), 'Undo restores only the date fields');
    assert.deepEqual(otherFields(await fullRows()), otherFields(initialFullRows), 'Undo must preserve all other database columns');
    await assert.rejects(core.undo(adapter, plan, appliedJournal.records, { ...approved, approvedJournalDigest: core.hash(appliedJournal.records) }, journal('stale-undo')), /undo-state-changed-or-not-applied/);
    const newPlan = await core.plan(adapter, { ownerId, limit: 10, pageSize: 10 });
    await db.updateTable('asset').set({ isFavorite: true }).where('id', '=', assetId).where('ownerId', '=', ownerId).execute();
    await assert.rejects(core.apply(adapter, newPlan, { approvedDigest: core.hash(newPlan), acknowledgeHistoryAmbiguity: true }, journal('concurrent')), /stale-plan/);
    assert.deepEqual(core.beforeDates(await adapter.snapshot(assetId)), core.beforeDates(initial), 'Concurrent edit cannot be overwritten');
    assert.deepEqual(await fs.readFile(originalPath), png, 'Original fixture bytes must remain unchanged');
    assert.equal(await adapter.sidecarsAbsent(originalPath), true, 'No sidecar may be written');
    assert.equal((await db.selectFrom('asset_file').select(sql`count(*)::int`.as('n')).where('assetId', '=', assetId).executeTakeFirst()).n, 0);
    stage = 'guided-user-list-read-only';
    const { MetadataRepository } = req(path.join(server, 'dist/repositories/metadata.repository.js'));
    const originalConcurrency = MetadataRepository.prototype.setMaxConcurrency;
    let readersStarted = 0;
    MetadataRepository.prototype.setMaxConcurrency = function (...args) { readersStarted++; return originalConcurrency.apply(this, args); };
    let accountList;
    try {
      const accountReader = await createAdapter({ releaseRoot, usersOnly: true });
      try {
        assert.equal(accountReader.readMetadata, undefined, 'User listing must not expose a media reader');
        assert.equal(accountReader.transaction, undefined, 'User listing must not expose mutations');
        accountList = await accountReader.listUsers();
      } finally { await accountReader.close(); }
      assert.equal(readersStarted, 0, 'User listing must not construct an ExifTool-backed reader');
    } finally { MetadataRepository.prototype.setMaxConcurrency = originalConcurrency; }
    const selection = String(accountList.findIndex(user => user.id === ownerId) + 1);
    assert.notEqual(selection, '0', 'The real fixture user must appear in the account list');
    const beforeGuided = await fullRows();
    const guidedOptions = { releaseRoot, outputRoot: path.join(fixture, 'guided'), language: 'ja' };
    const scripted = answers => {
      const output = [], questions = [];
      return { output, questions, write(line) { output.push(line); }, async ask(prompt) { questions.push(prompt); return answers.length ? answers.shift() : null; } };
    };
    stage = 'guided-cancel-check';
    const cancelled = await runGuided(guidedOptions, scripted([selection, '0']));
    assert.equal(cancelled.status, 'cancelled');
    assert.equal(cancelled.applied, 0);
    assert.deepEqual(await fullRows(), beforeGuided, 'Declining the guided confirmation must leave all DB rows unchanged');
    assert(!(await fs.readdir(cancelled.directory)).some(name => name.endsWith('.jsonl')), 'Cancellation must not start a write journal');
    stage = 'guided-resumed-approved-flow-check';
    const oldPart = path.join(cancelled.directory, 'plan.json.part-0001.json');
    const oldPartBytes = await fs.readFile(oldPart);
    const originalReadTags = MetadataRepository.prototype.readTags;
    let resumedMetadataReads = 0, guided;
    const approvedIo = scripted([selection, '1']);
    MetadataRepository.prototype.readTags = function (...args) { resumedMetadataReads++; return originalReadTags.apply(this, args); };
    try { guided = await runGuided({ ...guidedOptions, resumeDirectory: cancelled.directory }, approvedIo); }
    finally { MetadataRepository.prototype.readTags = originalReadTags; }
    assert.equal(resumedMetadataReads, 1, 'Resume reuses planning evidence; only apply revalidates original metadata');
    assert.deepEqual(await fs.readFile(oldPart), oldPartBytes, 'Resuming must preserve old plan bytes');
    assert.equal(guided.status, 'complete');
    assert.equal(guided.applied, 1);
    assert.equal(approvedIo.questions.length, 2, 'Only user selection and final confirmation are needed');
    const guidedIndex = JSON.parse(await fs.readFile(path.join(guided.directory, 'plan.json'), 'utf8'));
    assert.equal(guidedIndex.scope.ownerId, ownerId);
    assert.equal(guidedIndex.identity.timezone, 'Asia/Tokyo');
    assert.equal(guidedIndex.proposed, 1);
    assert.equal(guidedIndex.chunks[0].sourceDirectory, await fs.realpath(cancelled.directory));
    assert.equal((await fs.readdir(guided.directory)).filter(name => name.endsWith('.apply.jsonl')).length, 1);
    const afterGuided = await fullRows();
    assert.deepEqual(otherFields(afterGuided), otherFields(beforeGuided), 'Guided repair changes no other database columns');
    assert.equal(Date.parse(afterGuided.asset.localDateTime), Date.parse(expectedLocal));
    assert.equal(afterGuided.exif.timeZone, 'Asia/Tokyo');
    stage = 'guided-no-eligible-repeat-check';
    const emptyIo = scripted([selection]);
    const empty = await runGuided(guidedOptions, emptyIo);
    assert.equal(empty.status, 'empty');
    assert.equal(empty.applied, 0);
    assert.equal(emptyIo.questions.length, 1, 'An empty plan must not ask to apply');
    assert.deepEqual(await fullRows(), afterGuided, 'A repeated guided run must not add another offset');
    assert.deepEqual(await fs.readFile(originalPath), png, 'Guided repair must preserve original fixture bytes');
    process.stdout.write('PASS installed metadata repair: compiled imports, actual ExifTool, real Kysely/CAS/triggers, atomic rollback, journal failure, apply/undo/reconcile, stale plan and repeat guards, guided user listing/cancel/apply/empty flow; synthetic PNG unchanged.\n');
  } finally {
    let cleanupError;
    const clean = async (fn) => { try { await fn(); } catch (error) { cleanupError ||= error; } };
    await clean(() => adapter?.close());
    for (const handle of handles) await clean(() => handle.close());
    if (wroteFixture) {
      // Exact random fixture ownership only. Do not drop the CI database/schema,
      // disable triggers, delete other users, or clean arbitrary media paths.
      await clean(() => db.transaction().execute(async tx => {
        await tx.deleteFrom('asset').where('id', '=', assetId).where('ownerId', '=', ownerId).execute();
        await tx.deleteFrom('user').where('id', '=', ownerId).where('clusterGroupId', '=', clusterId).where('email', '=', `${ownerId}@metadata-repair.invalid`).execute();
        await tx.deleteFrom('cluster_group').where('id', '=', clusterId).where('name', '=', 'metadata-repair-ci').execute();
        await tx.deleteFrom('asset_audit').where('assetId', '=', assetId).where('ownerId', '=', ownerId).execute();
        await tx.deleteFrom('user_audit').where('userId', '=', ownerId).execute();
      }));
    }
    await clean(() => db.destroy());
    if (fixture && inside(temporary, fixture) && path.basename(fixture).startsWith('immich-date-repair-ci-')) await clean(() => fs.rm(fixture, { recursive: true }));
    if (cleanupError) throw new Error('Fixture cleanup failed');
  }
}
test().catch(error => {
  // A stable stage and source line locate failures without values, paths, SQL,
  // assertion diffs, connection settings, or credentials in the public log.
  const line = /Metadata-DateRepair-Integration\.cjs:(\d+):\d+/.exec(error.stack || '')?.[1];
  const errorClass = ['Error','SyntaxError','ReferenceError','TypeError','RangeError','AssertionError'].includes(error.name) ? error.name : 'Error';
  const code = typeof error.code === 'string' && /^[a-z0-9_-]+$/i.test(error.code) ? error.code : 'test-failure';
  process.stderr.write(`Metadata repair integration failed: ${JSON.stringify({ stage, code, errorClass, line })}\n`);
  process.exitCode = 1;
});
