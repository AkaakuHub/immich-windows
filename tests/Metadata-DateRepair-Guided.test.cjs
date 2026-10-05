'use strict';
// Exercise the production guided runner. Fixtures never connect to a database.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Readable, Writable } = require('node:stream');
const core = require('../runtime/metadata-date-repair/core.cjs');
const cli = require('../runtime/metadata-date-repair/cli.cjs');
const guided = require('../runtime/metadata-date-repair/guided.cjs');

const ID = n => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
const USERS = [
  { id: ID(900), name: 'First Owner', email: 'first@example.invalid' },
  { id: ID(901), name: 'Chosen Owner', email: 'chosen@example.invalid' },
];
const TIMEZONE = 'Asia/Tokyo';

async function fixture(t, settings = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'guided-date-repair-test-'));
  await fs.chmod(root, 0o700);
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const options = { releaseRoot: path.join(root, 'release'), outputRoot: path.join(root, 'private'), language: settings.language || 'en' };
  const state = { root, options, calls: [], adapters: [], transcript: [], writes: 0, closed: 0, asks: 0 };
  const answers = [...(settings.answers || ['2', '1'])];
  const io = {
    write(line) { state.transcript.push({ type: 'write', text: line }); },
    async ask(prompt) {
      state.transcript.push({ type: 'ask', text: prompt });
      state.asks++;
      if (settings.beforeAnswer) await settings.beforeAnswer(state, state.asks);
      return answers.length ? answers.shift() : null;
    },
  };
  const dependencies = {
    async createAdapter(options) {
      state.adapters.push(options);
      return {
        identity: { timezone: TIMEZONE },
        async listUsers() {
          if (settings.usersError) throw settings.usersError;
          return structuredClone(settings.users === undefined ? USERS : settings.users);
        },
        async close() { state.closed++; },
      };
    },
    async run(argv, hooks) {
      const parsed = cli.parse([...argv]);
      state.calls.push({ argv: [...argv], options: parsed });
      if (parsed.command === 'plan-all') {
        state.indexFile = parsed.out;
        const index = {
          format: core.INDEX_FORMAT,
          createdAt: '2026-10-05T00:00:00.000Z',
          identity: { timezone: TIMEZONE, upstreamCommit: 'synthetic-guided-fixture' },
          historyWarning: core.HISTORY_WARNING,
          scope: { ownerId: parsed['owner-id'], maxCandidates: 100000, chunkSize: 1000 },
          inspected: 5, proposed: 2, exhausted: true, nextAfterId: null, chunks: [],
          ...(settings.index || {}),
        };
        state.index = index;
        // Match CLI output semantics: a real private text file plus its exact digest.
        await fs.writeFile(state.indexFile, JSON.stringify(index) + '\n', { flag: 'wx', mode: 0o600 });
        hooks.onEvent?.({ kind: 'plan-progress', inspected: 3, proposed: 1 });
        hooks.onEvent?.({ kind: 'plan-progress', inspected: index.inspected, proposed: index.proposed });
        state.plannedDigest = core.hash(index);
        return { indexDigest: settings.resultDigest || state.plannedDigest };
      }
      assert.equal(parsed.command, 'apply-all');
      if (settings.realApply) return cli.run(argv, hooks);
      const current = JSON.parse(await fs.readFile(parsed.index, 'utf8'));
      core.insist(core.hash(current) === parsed['approved-index-sha256'], 'index-not-approved-or-owner-mismatch');
      state.writes++;
      hooks.onEvent?.({ kind: 'apply-progress', completed: 1 });
      if (settings.applyError) throw settings.applyError;
      hooks.onEvent?.({ kind: 'apply-progress', completed: current.proposed });
      return { completed: settings.completed === undefined ? current.proposed : settings.completed };
    },
  };
  state.output = () => state.transcript.map(event => event.text).join('\n');
  state.run = () => guided.runGuided(options, io, dependencies);
  return state;
}

test('selecting a nonfirst owner passes that exact owner and installed timezone to plan and apply', async t => {
  const f = await fixture(t);
  const result = await f.run();
  assert.equal(result.status, 'complete');
  assert.equal(result.applied, 2);
  assert.equal(f.writes, 1);
  assert.deepEqual(f.adapters, [{ releaseRoot: f.options.releaseRoot, usersOnly: true }]);
  assert.equal(f.closed, 1);
  assert.deepEqual(f.calls.map(call => call.options.command), ['plan-all', 'apply-all']);
  for (const { options } of f.calls) {
    assert.equal(options['owner-id'], USERS[1].id);
    assert.equal(options['expected-timezone'], TIMEZONE);
    assert.equal(options['release-root'], f.options.releaseRoot);
  }
  const applied = f.calls[1].options;
  assert.equal(applied['approved-index-sha256'], f.plannedDigest);
  assert.equal(applied['acknowledge-history-ambiguity'], true);
  assert.equal(applied.index, f.indexFile);
  assert.equal(applied['journal-dir'], result.directory);
  assert.match(f.output(), /Selected user: Chosen Owner \(chosen@example\.invalid\)/);
  assert.match(f.output(), /Installed server timezone: Asia\/Tokyo/);
  assert.match(f.output(), /Repaired: 2 \/ 2/);
  assert.match(f.output(), /Repair completed\./);
});

test('counts, exclusions and the full history warning precede approval', async t => {
  const f = await fixture(t, { beforeAnswer(state, number) {
    if (number !== 2) return;
    const output = state.output();
    assert.match(output, /Candidates checked: 5/);
    assert.match(output, /Dates to repair: 2/);
    assert.match(output, /Excluded by safety checks: 3/);
    assert(output.includes(core.HISTORY_WARNING));
    assert.match(output, /Original capture instants and image files are preserved/);
    assert.equal(state.calls.length, 1);
    assert.equal(state.writes, 0);
    const prompt = state.transcript.at(-1);
    assert.equal(prompt.type, 'ask');
    assert.match(prompt.text, /Accept this uncertainty/);
  } });
  await f.run();
  assert.equal(f.asks, 2);
  assert.match(f.output(), /Candidates checked: 3; Dates to repair: 1/);
});

for (const [name, answer] of [['zero', '0'], ['blank', ''], ['EOF', null]]) {
  test(`${name} at owner selection cancels before scanning or output creation`, async t => {
    const f = await fixture(t, { answers: [answer] });
    assert.deepEqual(await f.run(), { status: 'cancelled', applied: 0 });
    assert.equal(f.calls.length, 0);
    assert.equal(f.closed, 1);
    assert.equal(f.writes, 0);
    assert.equal(f.asks, 1);
    assert.deepEqual(await fs.readdir(f.root), []);
    assert.match(f.output(), /Cancelled\. No dates were changed\./);
  });
  test(`${name} at confirmation keeps the private plan and never applies`, async t => {
    const f = await fixture(t, { answers: ['2', answer] });
    const result = await f.run();
    assert.equal(result.status, 'cancelled');
    assert.equal(result.applied, 0);
    assert.equal(f.calls.length, 1);
    assert.equal(f.writes, 0);
    assert.equal(f.asks, 2);
    assert.equal(core.hash(JSON.parse(await fs.readFile(f.indexFile, 'utf8'))), f.plannedDigest);
    assert(f.output().includes(result.directory));
    assert(!f.output().includes('Repair completed.'));
  });
}

test('an empty user directory exits before prompts, scan or private output', async t => {
  const f = await fixture(t, { users: [] });
  assert.deepEqual(await f.run(), { status: 'empty-users', applied: 0 });
  assert.equal(f.asks, 0);
  assert.equal(f.calls.length, 0);
  assert.equal(f.closed, 1);
  assert.deepEqual(await fs.readdir(f.root), []);
  assert.match(f.output(), /No active Immich users were found/);
});

test('a fully scanned but ineligible scope never asks for approval or applies', async t => {
  const f = await fixture(t, { index: { inspected: 5, proposed: 0 } });
  const result = await f.run();
  assert.equal(result.status, 'empty');
  assert.equal(result.applied, 0);
  assert.equal(f.asks, 1);
  assert.equal(f.calls.length, 1);
  assert.equal(f.writes, 0);
  assert.match(f.output(), /Excluded by safety checks: 5/);
  assert.match(f.output(), /No eligible dates to repair/);
  assert(!f.output().includes('Accept this uncertainty'));
});

test('the incomplete 100,000-candidate bound never offers apply even with proposed repairs', async t => {
  const f = await fixture(t, { index: { inspected: 100000, proposed: 99000, exhausted: false, nextAfterId: ID(100000) } });
  const result = await f.run();
  assert.equal(result.status, 'incomplete');
  assert.equal(result.applied, 0);
  assert.equal(f.asks, 1);
  assert.equal(f.calls.length, 1);
  assert.equal(f.writes, 0);
  assert.match(f.output(), /100,000-candidate safety limit was reached/);
  assert.match(f.output(), /scan is incomplete; no dates were changed/);
  assert(!f.output().includes('Accept this uncertainty'));
});

test('changing a plan during the confirmation is rejected by the actual CLI using the original approval digest', async t => {
  let changedDigest;
  const f = await fixture(t, { realApply: true, async beforeAnswer(state, number) {
    if (number !== 2) return;
    const changed = JSON.parse(await fs.readFile(state.indexFile, 'utf8'));
    changed.proposed++;
    changedDigest = core.hash(changed);
    await fs.writeFile(state.indexFile, JSON.stringify(changed) + '\n');
  } });
  await assert.rejects(f.run, error => error.code === 'index-not-approved-or-owner-mismatch');
  assert.equal(f.calls.length, 2);
  assert.equal(f.calls[1].options['approved-index-sha256'], f.plannedDigest);
  assert.notEqual(f.calls[1].options['approved-index-sha256'], changedDigest);
  assert.equal(f.writes, 0);
  assert.deepEqual(await fs.readdir(path.dirname(f.indexFile)), ['plan.json']);
  assert.match(f.output(), /Stopped before completion\. Error code: index-not-approved-or-owner-mismatch/);
});

for (const [name, index, code] of [
  ['wrong owner', { scope: { ownerId: USERS[0].id } }, 'guided-plan-identity-mismatch'],
  ['wrong timezone', { identity: { timezone: 'UTC' } }, 'guided-plan-identity-mismatch'],
  ['wrong format', { format: 'untrusted-format' }, 'guided-plan-identity-mismatch'],
  ['fractional count', { inspected: 5.5 }, 'guided-plan-count-mismatch'],
  ['negative proposed count', { proposed: -1 }, 'guided-plan-count-mismatch'],
  ['more proposed than inspected', { inspected: 1, proposed: 2 }, 'guided-plan-count-mismatch'],
]) {
  test(`a planned index with ${name} stops before confirmation`, async t => {
    const f = await fixture(t, { index });
    await assert.rejects(f.run, error => error.code === code);
    assert.equal(f.asks, 1);
    assert.equal(f.calls.length, 1);
    assert.equal(f.writes, 0);
  });
}

test('a plan-result digest mismatch stops before confirmation', async t => {
  const f = await fixture(t, { resultDigest: '0'.repeat(64) });
  await assert.rejects(f.run, error => error.code === 'guided-plan-identity-mismatch');
  assert.equal(f.asks, 1);
  assert.equal(f.calls.length, 1);
  assert.equal(f.writes, 0);
});

test('failure after an apply write reports uncertainty and saved evidence without retry or raw error leakage', async t => {
  const error = new Error('synthetic SQL/password/private metadata must never be displayed');
  const f = await fixture(t, { applyError: error });
  await assert.rejects(f.run, thrown => thrown === error);
  assert.equal(f.calls.filter(call => call.options.command === 'apply-all').length, 1);
  assert.equal(f.writes, 1);
  assert.match(f.output(), /Stopped before completion\. Error code: operation-failed/);
  assert.match(f.output(), /Earlier changes may already be committed/);
  assert.match(f.output(), /reconcile them before retrying/);
  assert(f.output().includes(path.dirname(f.indexFile)));
  assert(!f.output().includes(error.message));
  assert(!f.output().includes('Repair completed.'));
});

test('an unexpected completed count reports an uncertain stopped apply rather than success', async t => {
  const f = await fixture(t, { completed: 1 });
  await assert.rejects(f.run, error => error.code === 'guided-apply-count-mismatch');
  assert.equal(f.writes, 1);
  assert.equal(f.calls.length, 2);
  assert.match(f.output(), /Earlier changes may already be committed/);
  assert(!f.output().includes('Repair completed.'));
});

test('user lookup failure closes its adapter and stops without scanning', async t => {
  const error = new Error('synthetic directory error');
  const f = await fixture(t, { usersError: error });
  await assert.rejects(f.run, thrown => thrown === error);
  assert.equal(f.closed, 1);
  assert.equal(f.asks, 0);
  assert.equal(f.calls.length, 0);
  assert(!f.output().includes('Earlier changes may already be committed'));
});

test('the displayed recovery directory exists under the requested private root and is preserved', async t => {
  const f = await fixture(t);
  const result = await f.run();
  assert.equal(path.dirname(result.directory), await fs.realpath(f.options.outputRoot));
  assert.match(path.basename(result.directory), /^repair-/);
  assert.equal(path.dirname(f.indexFile), result.directory);
  const saved = f.transcript.filter(event => event.text.startsWith('Private plan and recovery journals: '));
  assert.equal(saved.length, 2);
  assert(saved.every(event => event.text.endsWith(result.directory)));
  const scanning = f.transcript.findIndex(event => event.text.startsWith('Checking suspicious dates'));
  assert(f.transcript.indexOf(saved[0]) < scanning);
  assert.equal((await fs.stat(f.indexFile)).isFile(), true);
  if (process.platform !== 'win32') {
    assert.equal((await fs.stat(f.options.outputRoot)).mode & 0o077, 0);
    assert.equal((await fs.stat(result.directory)).mode & 0o077, 0);
    assert.equal((await fs.stat(f.indexFile)).mode & 0o077, 0);
  }
});

test('invalid owner and approval answers cannot choose a user or imply consent', async t => {
  const f = await fixture(t, { answers: ['-1', '01', '1.0', 'yes', '3', '2', 'yes', '2', '0'] });
  const result = await f.run();
  assert.equal(result.status, 'cancelled');
  assert.equal(f.asks, 9);
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].options['owner-id'], USERS[1].id);
  assert.equal(f.writes, 0);
  assert.equal(f.transcript.filter(event => event.text === 'Enter one of the displayed numbers.').length, 7);
});

test('user labels sanitize terminal control characters and directional overrides', async t => {
  const unsafe = 'Bad\r\n\x1b[2J\x00\x7f\x9b\u202e\u2066Owner';
  const f = await fixture(t, { users: [{ id: USERS[0].id, name: unsafe, email: unsafe + '@example.invalid' }], answers: ['1', '0'] });
  await f.run();
  const displayed = f.transcript.filter(event => /^1\. |^Selected user: /.test(event.text));
  assert.equal(displayed.length, 2);
  assert(displayed.every(event => !/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/.test(event.text)));
  assert.equal(guided.label('x'.repeat(200)).length, 160);
  assert.equal(guided.label('Safe 日本語'), 'Safe 日本語');
});

test('Japanese repair shows localized history uncertainty before confirmation', async t => {
  const f = await fixture(t, { language: 'ja', answers: ['2', '0'], beforeAnswer(state, number) {
    if (number === 2) {
      assert.match(state.output(), /以前のデータベース上の手動日付編集/);
      assert.match(state.output(), /過去の手動編集がなかったことまでは証明できません/);
    }
  } });
  assert.equal((await f.run()).status, 'cancelled');
  assert.match(f.output(), /確認した候補: 5/);
  assert.match(f.output(), /修復対象: 2/);
  assert.match(f.output(), /安全性の確認で除外: 3/);
  assert.match(f.output(), /日付は変更していません/);
});

test('terminal input trims answers, preserves blank cancellation and represents EOF as null', async () => {
  let output = '';
  const sink = new Writable({ write(chunk, encoding, callback) { output += chunk.toString(); callback(); } });
  const io = guided.terminal(Readable.from(['  2  \n', '\n']), sink);
  try {
    assert.equal(await io.ask('Choose'), '2');
    assert.equal(await io.ask('Approve'), '');
    assert.equal(await io.ask('After EOF'), null);
    io.write('Done');
    assert.match(output, /Choose\n> /);
    assert.match(output, /Done\n$/);
  } finally { io.close(); }
});

test('guided arguments accept only one absolute release/output path and supported language', () => {
  const root = path.resolve(os.tmpdir(), 'synthetic-guided-arguments');
  const valid = ['--release-root', root, '--output-root', path.join(root, 'private'), '--language', 'en'];
  assert.deepEqual(guided.parse(valid), { releaseRoot: root, outputRoot: path.join(root, 'private'), language: 'en' });
  assert.equal(guided.parse([...valid.slice(0, -1), 'ja']).language, 'ja');
  for (const invalid of [
    [], ['--language', 'en'],
    valid.slice(0, -1), [...valid, '--unknown', 'value'], [...valid, '--apply'],
    [...valid, '--language', 'ja'], [...valid, '--release-root', root], [...valid, '--output-root', root],
    ['--release-root', '--output-root', root, '--language', 'en'],
    ['--release-root', 'relative', ...valid.slice(2)],
    [...valid.slice(0, 2), '--output-root', 'relative', '--language', 'en'],
    [...valid.slice(0, -1), 'fr'], [...valid.slice(0, -1), ''],
    [...valid, 'positional', 'value'],
  ]) assert.throws(() => guided.parse(invalid), error => error instanceof core.Stop, JSON.stringify(invalid));
});

function scanAdapter(count) {
  const rows = Array.from({ length: count }, (_, i) => ({ asset: { id: ID(i + 1), ownerId: USERS[1].id } }));
  return {
    identity: { timezone: TIMEZONE, fixture: 'read-only excluded records' },
    async candidates({ ownerId, afterId, limit }) {
      assert.equal(ownerId, USERS[1].id);
      return rows.filter(row => !afterId || row.asset.id > afterId).slice(0, limit).map(row => structuredClone(row));
    },
    async transaction() { assert.fail('planning must never open a write transaction'); },
  };
}

function withoutTimestamp(value) { const result = structuredClone(value); delete result.createdAt; return result; }

test('core plan progress reports page counts without altering the plan or write behavior', async () => {
  const options = { ownerId: USERS[1].id, limit: 10, pageSize: 2 };
  const plain = await core.plan(scanAdapter(5), options);
  const progress = [];
  const observed = await core.plan(scanAdapter(5), { ...options, onProgress(event) {
    progress.push({ ...event });
    event.inspected = -1;
    event.proposed = 999;
  } });
  assert.deepEqual(progress, [{ inspected: 2, proposed: 0 }, { inspected: 4, proposed: 0 }, { inspected: 5, proposed: 0 }]);
  assert.deepEqual(withoutTimestamp(observed), withoutTimestamp(plain));
  assert.equal(observed.exhausted, true);
  assert.equal(observed.excluded.length, 5);
});

test('core plan-all progress is cumulative across chunks and observational', async () => {
  async function run(onProgress) {
    const chunks = [];
    const index = await core.planAll(scanAdapter(1002), { ownerId: USERS[1].id, maxCandidates: 2000, pageSize: 100, onProgress }, async (plan, n) => {
      chunks.push(withoutTimestamp(plan));
      return { file: `chunk-${n}.json`, sha256: 'synthetic-byte-digest' };
    });
    const comparable = withoutTimestamp(index);
    comparable.chunks.forEach(chunk => delete chunk.planDigest);
    return { index, comparable, chunks };
  }
  const plain = await run();
  const progress = [];
  const observed = await run(event => { progress.push({ ...event }); event.inspected = -1; });
  assert.deepEqual(observed.comparable, plain.comparable);
  assert.deepEqual(observed.chunks, plain.chunks);
  assert.equal(progress.length, 11);
  assert.deepEqual(progress.at(-2), { inspected: 1000, proposed: 0 });
  assert.deepEqual(progress.at(-1), { inspected: 1002, proposed: 0 });
  assert.equal(observed.index.inspected, 1002);
  assert.equal(observed.index.chunks.length, 2);
  assert.equal(observed.index.exhausted, true);
});
