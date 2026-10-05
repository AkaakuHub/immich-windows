#!/usr/bin/env node
'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const core = require('./core.cjs');
const HELP = `Immich date repair: guarded date-field maintenance; use Repair-MetadataDates.cmd for guided repair.
Default command: plan (read-only database, bounded metadata reads, text plan only).
Commands:
  plan-all --release-root ABSOLUTE --owner-id UUID --expected-timezone IANA --out INDEX.json
           [--max-candidates COUNT] [--page-size 25] [--resume-directory ABSOLUTE] (no total limit unless supplied)
  apply-all --release-root ABSOLUTE --owner-id UUID --expected-timezone IANA --index INDEX.json
            --approved-index-sha256 DIGEST --journal-dir PRIVATE_DIRECTORY
            --acknowledge-history-ambiguity
  plan --release-root ABSOLUTE --owner-id UUID --expected-timezone IANA --out PLAN.json
       [--limit 100] [--page-size 25] [--after-id UUID]
  review --plan PLAN.json
  self-test --release-root ABSOLUTE --expected-timezone IANA
  apply --release-root ABSOLUTE --owner-id UUID --expected-timezone IANA
        --plan PLAN.json --approved-plan-sha256 DIGEST --journal NEW.jsonl
        --acknowledge-history-ambiguity
  reconcile --release-root ABSOLUTE --owner-id UUID --expected-timezone IANA
            --plan PLAN.json --approved-plan-sha256 DIGEST --journal EXISTING.jsonl
  undo --release-root ABSOLUTE --owner-id UUID --expected-timezone IANA
       --plan PLAN.json --approved-plan-sha256 DIGEST --source-journal EXISTING.jsonl
       --approved-journal-sha256 DIGEST --journal NEW.jsonl
       --acknowledge-history-ambiguity
No command changes server settings, restarts services, enqueues jobs, or writes media.
An approval digest/acknowledgement is a deliberate operator gate, not proof of history.
`;
function parse(argv) {
  let command = 'plan';
  if (argv[0] && !argv[0].startsWith('--')) command = argv.shift();
  core.insist(['plan','plan-all','apply-all','review','self-test','apply','reconcile','undo'].includes(command), 'unknown-command');
  const allowed = new Set(['release-root','owner-id','expected-timezone','out','limit','page-size','after-id','plan','approved-plan-sha256','journal','source-journal','approved-journal-sha256','acknowledge-history-ambiguity','max-candidates','index','approved-index-sha256','journal-dir','resume-directory','help']);
  const opts = { command };
  while (argv.length) {
    const key = argv.shift();
    core.insist(key.startsWith('--') && allowed.has(key.slice(2)) && !(key.slice(2) in opts), 'unknown-or-duplicate-option');
    const name = key.slice(2);
    if (['help','acknowledge-history-ambiguity'].includes(name)) opts[name] = true;
    else { const value = argv.shift(); core.insist(value && !value.startsWith('--'), 'missing-option-value'); opts[name] = value; }
  }
  const common = ['help'];
  const runtime = ['release-root','owner-id','expected-timezone'];
  const approval = ['plan','approved-plan-sha256','journal'];
  const perCommand = {
    plan: [...runtime,'out','limit','page-size','after-id'],
    'plan-all': [...runtime,'out','max-candidates','page-size','after-id','resume-directory'],
    'apply-all': [...runtime,'index','approved-index-sha256','journal-dir','acknowledge-history-ambiguity'],
    review: ['plan'],
    'self-test': ['release-root','expected-timezone'],
    apply: [...runtime,...approval,'acknowledge-history-ambiguity'],
    reconcile: [...runtime,...approval],
    undo: [...runtime,...approval,'source-journal','approved-journal-sha256','acknowledge-history-ambiguity'],
  };
  for (const key of Object.keys(opts)) core.insist(key === 'command' || common.includes(key) || perCommand[command].includes(key), 'option-not-valid-for-command');
  return opts;
}
async function readJson(file) { const data = await fs.readFile(file, 'utf8'); core.insist(Buffer.byteLength(data) <= 16 * 1024 * 1024, 'input-too-large'); return JSON.parse(data.replace(/^\uFEFF/, '')); }
async function readJournal(file) {
  const text = await fs.readFile(file, 'utf8'); core.insist(Buffer.byteLength(text) <= 16 * 1024 * 1024, 'input-too-large');
  const truncatedTail = !text.endsWith('\n');
  const lines = text.split('\n'); lines.pop(); // Ignore an incomplete tail; DB reconciliation decides commit state
  const records = lines.map(line => JSON.parse(line));
  core.insist(records[0]?.format === core.FORMAT && ['apply','undo'].includes(records[0]?.operation), 'invalid-journal-header');
  core.insist(records.every(r => r && typeof r === 'object'), 'invalid-journal-record');
  return { records, truncatedTail };
}
async function exclusive(file, extension) {
  core.insist(typeof file === 'string' && file.toLowerCase().endsWith(extension), 'text-output-extension-required');
  const parent = await fs.realpath(path.dirname(path.resolve(file)));
  const resolved = path.join(parent, path.basename(file));
  return fs.open(resolved, 'wx', 0o600);
}
function fileJournal(handle) {
  let headerWritten = false;
  async function appendSync(record) { await handle.writeFile(JSON.stringify(record) + '\n'); await handle.sync(); }
  return { async header(record) { core.insist(!headerWritten, 'duplicate-journal-header'); await appendSync(record); headerWritten = true; }, appendSync };
}
async function writeAndClose(handle, text) {
  let primary;
  try { await handle.writeFile(text); await handle.sync(); } catch (error) { primary = error; throw error; }
  finally { try { await handle.close(); } catch (error) { if (!primary) throw error; } }
}
async function writeCheckpoint(file, index, fileSystem = fs) {
  const temporary = file + '.checkpoint-' + randomUUID() + '.tmp';
  const handle = await fileSystem.open(temporary, 'wx', 0o600);
  await writeAndClose(handle, JSON.stringify(index, null, 2) + '\n');
  await fileSystem.rename(temporary, file);
}
async function persistFailure(directory, details, { cleanup = false, fileSystem = fs } = {}) {
  const file = path.join(directory, cleanup ? 'failure-cleanup.json' : 'failure.json');
  const handle = await fileSystem.open(file, 'wx', 0o600);
  await writeAndClose(handle, JSON.stringify({ format: 'immich-date-repair/failure-v1', timestamp: new Date().toISOString(), ...details }, null, 2) + '\n');
  return file;
}
async function run(argv, { onEvent, onFailure, emit = record => process.stdout.write(JSON.stringify(record) + '\n') } = {}) {
  let result;
  const report = record => { result = record; emit(record); };
  const o = parse([...argv]);
  for (const key of ['out','plan','journal','source-journal','index','journal-dir','resume-directory']) if (o[key]) o[key] = path.resolve(o[key]);
  if (o.help || argv.length === 0) { process.stdout.write(HELP); return; }
  if (o.command === 'review') {
    const p = await readJson(o.plan);
    if (p.format === core.INDEX_FORMAT) { process.stdout.write(JSON.stringify({indexDigest:core.hash(p),ownerId:p.scope.ownerId,timezone:p.identity.timezone,chunks:p.chunks.length,inspected:p.inspected,proposed:p.proposed,exhausted:p.exhausted,nextAfterId:p.nextAfterId,historyWarning:p.historyWarning})+'\n'); return; }
    core.insist(p.format === core.FORMAT, 'invalid-plan-format');
    process.stdout.write(JSON.stringify({ planDigest: core.hash(p), ownerId: p.scope.ownerId, timezone: p.identity.timezone, inspected: p.inspected, proposed: p.entries.length, exhausted: p.exhausted, nextAfterId: p.nextAfterId, historyWarning: p.historyWarning }) + '\n'); return;
  }
  core.insist(o['release-root'] && o['expected-timezone'], 'runtime-and-timezone-required');
  if (o.command !== 'self-test') core.insist(o['owner-id'], 'owner-id-required');
  const mutation = ['apply','undo'].includes(o.command);
  const batchMutation = o.command === 'apply-all';
  if (batchMutation) core.insist(o['acknowledge-history-ambiguity'] && /^[0-9a-f]{64}$/.test(o['approved-index-sha256'] || ''), 'explicit-later-index-approval-required');
  if (mutation) core.insist(o['acknowledge-history-ambiguity'] && /^[0-9a-f]{64}$/.test(o['approved-plan-sha256'] || ''), 'explicit-later-approval-required');
  let p, source, index;
  if (batchMutation) { index = await readJson(o.index); core.insist(core.hash(index) === o['approved-index-sha256'] && index.scope?.ownerId === o['owner-id'], 'index-not-approved-or-owner-mismatch'); }
  if (['apply','undo','reconcile'].includes(o.command)) {
    p = await readJson(o.plan);
    core.insist(p.scope?.ownerId === o['owner-id'], 'plan-owner-mismatch');
    core.insist(core.hash(p) === o['approved-plan-sha256'], 'plan-digest-not-approved');
  }
  if (['undo','reconcile'].includes(o.command)) {
    source = await readJournal(o.command === 'undo' ? o['source-journal'] : o.journal);
    core.insist(source.records[0].planDigest === core.hash(p), 'journal-plan-mismatch');
    for (const r of source.records.filter(r => r.kind === 'prepared')) {
      const e = p.entries.find(e => e.id === r.id);
      core.insist(e && (source.records[0].operation === 'undo' || (core.same(r.before, core.beforeDates(e.snapshot)) && core.same(r.after, e.after))), 'journal-entry-mismatch');
    }
    if (o.command === 'undo') core.insist(!source.truncatedTail, 'truncated-journal-review-required');
  }
  let handle, adapter, primaryError;
  const notifyFailure = async (error, options) => { if (onFailure) { try { await onFailure(error, options); } catch (logError) { process.stderr.write(JSON.stringify({ errorLogFailed: core.failureDetails(logError), original: core.failureDetails(error) }) + '\n'); } } };
  try {
    if (['plan','plan-all'].includes(o.command)) handle = await exclusive(o.out, '.json');
    if (mutation) handle = await exclusive(o.journal, '.jsonl');
    const { createAdapter } = require('./runtime.cjs');
    adapter = await core.atStage('runtime-init', () => createAdapter({ releaseRoot: o['release-root'], ownerId: o['owner-id'], connect: o.command !== 'self-test' }));
    core.insist(adapter.identity.timezone === o['expected-timezone'], 'configured-timezone-mismatch');
    if (o.command === 'self-test') { process.stdout.write(JSON.stringify({ command: 'self-test', passed: true, identity: adapter.identity, databaseOpened: false, mediaRead: false }) + '\n'); return; }
    if (o.command === 'plan-all') {
      core.insist(!o['resume-directory'] || !o['after-id'], 'resume-and-cursor-conflict');
      await handle.close(); handle = null; // The reserved index is atomically checkpointed below.
      const initialIndex = o['resume-directory'] ? await core.atStage('resume-read', () => require('./resume.cjs').prepareResume({ directory: o['resume-directory'], adapter, ownerId: o['owner-id'], maximum: o['max-candidates'] === undefined ? null : Number(o['max-candidates']) })) : null;
      if (initialIndex) { await core.atStage('checkpoint-write', () => writeCheckpoint(o.out, initialIndex)); onEvent?.({kind:'resumed',inspected:initialIndex.inspected,proposed:initialIndex.proposed}); }
      const checkpoint = index => core.atStage('checkpoint-write', () => writeCheckpoint(o.out, index));
      const output = await core.planAll(adapter,{ownerId:o['owner-id'],maxCandidates:o['max-candidates'] === undefined ? null : Number(o['max-candidates']),pageSize:Number(o['page-size'] || 25),afterId:o['after-id'],onCheckpoint:checkpoint,onProgress:progress=>onEvent?.({kind:'plan-progress',...progress})},async (p,n) => {
        return core.atStage('chunk-write', async () => {
        const file = path.basename(o.out) + '.part-' + String(n).padStart(4,'0') + '.json';
        const text = JSON.stringify(p,null,2) + '\n'; const h = await exclusive(path.join(path.dirname(path.resolve(o.out)),file),'.json');
        await writeAndClose(h, text);
        return {file,sha256:createHash('sha256').update(text).digest('hex')};
        }, { chunk: n });
      }, initialIndex);
      await checkpoint(output);
      report({command:'plan-all',indexDigest:core.hash(output),chunks:output.chunks.length,inspected:output.inspected,proposed:output.proposed,exhausted:output.exhausted,nextAfterId:output.nextAfterId,applied:0});
    } else if (batchMutation) {
      const indexDir = path.dirname(path.resolve(o.index)), journalDir = await fs.realpath(o['journal-dir']);
      let committed = 0;
      const completed = await core.applyAll(adapter,index,{approvedIndexDigest:o['approved-index-sha256'],ownerId:o['owner-id'],acknowledgeHistoryAmbiguity:true},async chunk => {
        if (chunk.sourceDirectory) return require('./resume.cjs').readResumeChunk(chunk, { directory: indexDir });
        core.insist(typeof chunk.file === 'string' && !/[\\/]/.test(chunk.file) && chunk.file.startsWith(path.basename(o.index)+'.part-') && chunk.file.endsWith('.json'), 'invalid-chunk-path');
        const bytes = await fs.readFile(path.join(indexDir,chunk.file)); core.insist(bytes.length <= 16*1024*1024 && createHash('sha256').update(bytes).digest('hex') === chunk.sha256, 'chunk-file-digest-mismatch');
        return JSON.parse(bytes.toString('utf8'));
      },async chunk => { const h = await exclusive(path.join(journalDir,chunk.file+'.apply.jsonl'),'.jsonl'); const writer=fileJournal(h); return {...writer,async appendSync(record) { await writer.appendSync(record); if(record.kind === 'committed') onEvent?.({kind:'apply-progress',completed:++committed}); },close:()=>h.close()}; });
      report({command:'apply-all',completed,chunks:index.chunks.length});
    } else if (o.command === 'plan') {
      const output = await core.plan(adapter, { ownerId: o['owner-id'], limit: Number(o.limit || 100), pageSize: Number(o['page-size'] || 25), afterId: o['after-id'] });
      await handle.writeFile(JSON.stringify(output, null, 2) + '\n'); await handle.sync();
      process.stdout.write(JSON.stringify({ command: 'plan', planDigest: core.hash(output), inspected: output.inspected, proposed: output.entries.length, excluded: output.excluded.length, exhausted: output.exhausted, nextAfterId: output.nextAfterId, applied: 0 }) + '\n');
    } else if (o.command === 'reconcile') {
      core.validatePlan(p, adapter, o['approved-plan-sha256']);
      const states = await core.reconcile(adapter, source.records);
      process.stdout.write(JSON.stringify({ command: 'reconcile', readOnly: true, journalDigest: core.hash(source.records), truncatedTail: source.truncatedTail, states }) + '\n');
    } else {
      const options = { approvedDigest: o['approved-plan-sha256'], acknowledgeHistoryAmbiguity: o['acknowledge-history-ambiguity'] === true, approvedJournalDigest: o['approved-journal-sha256'] };
      const ids = o.command === 'apply' ? await core.apply(adapter, p, options, fileJournal(handle)) : await core.undo(adapter, p, source.records, options, fileJournal(handle));
      process.stdout.write(JSON.stringify({ command: o.command, completed: ids.length, ids }) + '\n');
    }
  } catch (error) {
    primaryError = error; await notifyFailure(error); throw error;
  } finally {
    let cleanupError;
    try { await core.atStage('cleanup-runtime', () => adapter?.close()); } catch (error) { cleanupError = error; }
    try { await core.atStage('cleanup-output', () => handle?.close()); } catch (error) { cleanupError ||= error; }
    if (cleanupError) { await notifyFailure(cleanupError, { cleanup: !!primaryError }); if (!primaryError) throw cleanupError; }
  }
  return result;
}
if (require.main === module) run(process.argv.slice(2)).catch(error => {
  // Never print raw DB errors, file paths, connection config, tags or SQL params.
  const code = error instanceof core.Stop ? error.code : 'operation-failed';
  process.stderr.write(JSON.stringify({ stopped: true, code, ...core.failureDetails(error), note: 'If applying or undoing, earlier IDs may already be committed. Do not retry uncertain writes; inspect and reconcile the journal first.' }) + '\n'); process.exitCode = 2;
});
module.exports = { writeCheckpoint, persistFailure, run, parse, readJournal, fileJournal, exclusive };
