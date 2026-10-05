'use strict';
// Only explicitly selected text plans are read. No media or database operations.
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const core = require('./core.cjs');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHA = /^[0-9a-f]{64}$/;
const PART = /^plan\.json\.part-([0-9]{4,})\.json$/;
const MAX_BYTES = 16 * 1024 * 1024;
// Exact 3793ff6ed3b6fd06f3dafbb271ca7d4d2f0ca0c3 files, as LF or CRLF.
// These fingerprints narrow compatibility; they do not authenticate old plans.
const KNOWN_TOOL_HASHES = Object.freeze([
  Object.freeze({
    'core.cjs': '1a870851d9dd4f163159c400e910be44dab742c4d0b967bd0e80490c68719c7c',
    'runtime.cjs': '7f953c65f4eab0095842ec6330a67009101efe8a5d34186903b625b6534504fd',
    'cli.cjs': '047c3920066ec26c65f6e26267a551c4c238f9575925b8bda6a97c84a63f5a24',
    'guided.cjs': '2e6f4ab2b04fa661c3cff9ebef78557bd33295de6e92047310a92c6ec85c23a0',
  }),
  Object.freeze({
    'core.cjs': '2734d35617c3288acfed8688e95318c57f94b1f9e515e6a4ef5f08983df74a83',
    'runtime.cjs': '2cb61604aa9adf3d81757b7fd8439e39f8d6af29a447e58a12008e7a8b3a0e44',
    'cli.cjs': '72fb427b17e59f5ef603a485edec2c80246a1bb77986452ce2f10752b8949d42',
    'guided.cjs': '3e28a3d3662e154385cbd8bc4fa228c0cef1ec12acb5ea32a05946c5dffb7645',
  }),
]);
function normalized(value) { const resolved = path.resolve(value); return process.platform === 'win32' ? resolved.toLowerCase() : resolved; }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function isCompatiblePlanIdentity(previous, current) {
  if (!isObject(previous) || !isObject(current)) return false;
  const { toolHashes: oldHashes, ...oldRuntime } = previous;
  const { toolHashes: newHashes, ...newRuntime } = current;
  const files = ['cli.cjs', 'core.cjs', 'guided.cjs', 'resume.cjs', 'runtime.cjs'];
  if (!isObject(newHashes) || !core.same(Object.keys(newHashes).sort(), files) || !Object.values(newHashes).every(v => typeof v === 'string' && SHA.test(v))) return false;
  return core.same(oldRuntime, newRuntime) && (core.same(oldHashes, newHashes) || KNOWN_TOOL_HASHES.some(hashes => core.same(oldHashes, hashes)));
}
function partName(n) { return 'plan.json.part-' + String(n).padStart(4, '0') + '.json'; }
function partNumber(file) {
  const match = typeof file === 'string' && PART.exec(file);
  const n = match && Number(match[1]);
  core.insist(Number.isSafeInteger(n) && n >= 1 && file === partName(n), 'invalid-resume-chunk-path');
  return n;
}
async function selectedDirectory(directory) {
  core.insist(typeof directory === 'string' && directory.length > 0 && !directory.includes('\0'), 'resume-directory-required');
  core.insist(!/^[\\/]{2}/.test(directory) && (process.platform !== 'win32' || /^[A-Za-z]:[\\/]/.test(directory)), 'resume-local-directory-required');
  const resolved = path.resolve(directory);
  const stat = await fs.lstat(resolved, { bigint: true });
  core.insist(stat.isDirectory() && !stat.isSymbolicLink() && normalized(await fs.realpath(resolved)) === normalized(resolved), 'unsafe-resume-directory');
  return { directory: resolved, dev: stat.dev, ino: stat.ino };
}
async function checkDirectory(selected) {
  const now = await selectedDirectory(selected.directory);
  core.insist(now.dev === selected.dev && now.ino === selected.ino, 'resume-directory-changed');
}
function unchanged(a, b) { return ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].every(k => a[k] === b[k]); }
async function readText(selected, file) {
  core.insist(file === 'plan.json' || PART.test(file), 'invalid-resume-chunk-path');
  await checkDirectory(selected);
  const full = path.join(selected.directory, file);
  const before = await fs.lstat(full, { bigint: true });
  core.insist(before.isFile() && !before.isSymbolicLink() && before.size <= BigInt(MAX_BYTES), 'unsafe-resume-file');
  core.insist(normalized(await fs.realpath(full)) === normalized(full), 'unsafe-resume-file');
  const handle = await fs.open(full, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  let bytes;
  try {
    const opened = await handle.stat({ bigint: true });
    core.insist(opened.isFile() && unchanged(before, opened), 'resume-file-changed');
    // A concurrent grow cannot make this read allocate an unbounded buffer.
    const buffer = Buffer.alloc(Number(opened.size) + 1);
    let used = 0;
    while (used < buffer.length) {
      const { bytesRead } = await handle.read(buffer, used, buffer.length - used, used);
      if (!bytesRead) break;
      used += bytesRead;
    }
    core.insist(used === Number(opened.size) && unchanged(opened, await handle.stat({ bigint: true })), 'resume-file-changed');
    bytes = buffer.subarray(0, used);
  } finally { await handle.close(); }
  await checkDirectory(selected);
  core.insist(unchanged(before, await fs.lstat(full, { bigint: true })) && normalized(await fs.realpath(full)) === normalized(full), 'resume-file-changed');
  return { text: bytes.toString('utf8'), sha256: createHash('sha256').update(bytes).digest('hex') };
}
function parse(text) {
  try { return JSON.parse(text.replace(/^\uFEFF/, '')); }
  catch { throw new core.Stop('invalid-resume-json'); }
}
function validatePart(p, adapter, ownerId, afterId) {
  core.insist(isObject(p) && p.format === core.FORMAT && p.historyWarning === core.HISTORY_WARNING, 'invalid-resume-plan');
  core.insist(isCompatiblePlanIdentity(p.identity, adapter.identity), 'resume-runtime-or-timezone-changed');
  core.insist(isObject(p.scope) && p.scope.ownerId === ownerId && p.scope.afterId === afterId, 'resume-owner-or-cursor-mismatch');
  core.insist(Number.isInteger(p.scope.limit) && p.scope.limit >= 1 && p.scope.limit <= 1000 && Number.isInteger(p.scope.pageSize) && p.scope.pageSize >= 1 && p.scope.pageSize <= 100, 'invalid-resume-scope');
  core.insist(typeof p.createdAt === 'string' && Number.isFinite(Date.parse(p.createdAt)) && /Z$/.test(p.createdAt), 'invalid-resume-created-at');
  core.insist(Array.isArray(p.entries) && Array.isArray(p.excluded) && Number.isInteger(p.inspected) && p.inspected >= 0 && p.inspected <= p.scope.limit && p.inspected === p.entries.length + p.excluded.length, 'invalid-resume-counts');
  core.insist(p.excluded.every(e => isObject(e) && typeof e.reason === 'string' && e.reason.length > 0), 'invalid-resume-exclusion');
  const ids = [...p.entries, ...p.excluded].map(e => e?.id).sort();
  core.insist(ids.every((id, i) => typeof id === 'string' && UUID.test(id) && (!afterId || id > afterId) && (!i || id > ids[i - 1])), 'invalid-resume-keyset');
  core.insist(new Set(ids.map(id => id.toLowerCase())).size === ids.length, 'invalid-resume-keyset');
  // Snapshot failure exclusions may be appended out of order by the old planner.
  core.insist(p.entries.every((e, i) => !i || e.id > p.entries[i - 1].id), 'invalid-resume-entry-order');
  const last = ids.at(-1) || afterId;
  core.insist(typeof p.exhausted === 'boolean' && (p.exhausted ? p.nextAfterId === null : p.inspected === p.scope.limit && p.inspected > 0 && p.nextAfterId === last), 'invalid-resume-continuation');
  try { core.validatePlan(p, { identity: p.identity }, core.hash(p)); }
  catch (error) { if (error instanceof core.Stop) throw error; throw new core.Stop('invalid-resume-entry'); }
  return { planDigest: core.hash(p), inspected: p.inspected, proposed: p.entries.length, nextAfterId: p.nextAfterId, exhausted: p.exhausted };
}
async function readResumeChunk(chunk, { directory }) {
  partNumber(chunk?.file);
  core.insist(typeof chunk.sha256 === 'string' && SHA.test(chunk.sha256) && typeof chunk.planDigest === 'string' && SHA.test(chunk.planDigest), 'invalid-resume-chunk-digest');
  const source = chunk.sourceDirectory === undefined ? directory : chunk.sourceDirectory;
  core.insist(typeof source === 'string' && (chunk.sourceDirectory === undefined || path.isAbsolute(source)), 'invalid-resume-source-directory');
  const selected = await selectedDirectory(source);
  const data = await readText(selected, chunk.file);
  core.insist(data.sha256 === chunk.sha256, 'resume-chunk-file-digest-mismatch');
  const p = parse(data.text);
  core.insist(core.hash(p) === chunk.planDigest, 'resume-chunk-plan-digest-mismatch');
  return p;
}
async function prepareResume({ directory, adapter, ownerId, maximum = null }) {
  core.insist(typeof ownerId === 'string' && UUID.test(ownerId), 'owner-id-required');
  core.insist(maximum === null || (Number.isSafeInteger(maximum) && maximum >= 1), 'invalid-total-bound');
  core.insist(isCompatiblePlanIdentity(adapter?.identity, adapter?.identity), 'invalid-resume-current-identity');
  const selected = await selectedDirectory(directory);
  const names = await fs.readdir(selected.directory);
  const localParts = names.filter(name => name.startsWith('plan.json.part-'));
  let checkpoint = null, checkpointSha256 = null;
  if (names.includes('plan.json')) {
    const data = await readText(selected, 'plan.json');
    checkpointSha256 = data.sha256;
    if (data.text.replace(/^\uFEFF/, '').trim()) {
      checkpoint = parse(data.text);
      core.insist(checkpoint?.format === core.INDEX_FORMAT && checkpoint.historyWarning === core.HISTORY_WARNING && isCompatiblePlanIdentity(checkpoint.identity, adapter.identity), 'invalid-resume-index');
      core.insist(checkpoint.scope?.ownerId === ownerId && checkpoint.scope.chunkSize === 1000 && (checkpoint.scope.maxCandidates === null || (Number.isSafeInteger(checkpoint.scope.maxCandidates) && checkpoint.scope.maxCandidates >= 1)) && Array.isArray(checkpoint.chunks) && checkpoint.chunks.length > 0, 'invalid-resume-index-scope');
    }
  }
  // Only direct references in the selected index are followed; no nested index is read.
  const refs = checkpoint ? checkpoint.chunks.map((chunk, i) => {
    core.insist(isObject(chunk) && chunk.file === partName(i + 1), 'resume-chunk-gap');
    core.insist(chunk.sourceDirectory === undefined || (typeof chunk.sourceDirectory === 'string' && path.isAbsolute(chunk.sourceDirectory)), 'invalid-resume-source-directory');
    return { ...chunk, sourceDirectory: chunk.sourceDirectory || selected.directory, recorded: true };
  }) : [];
  if (!checkpoint) {
    localParts.forEach(partNumber);
    localParts.sort((a, b) => partNumber(a) - partNumber(b));
  }
  // With a checkpoint, unreferenced tail files are uncommitted and rescanned.
  for (const file of checkpoint ? [] : localParts) {
    const number = partNumber(file);
    if (number <= refs.length) {
      core.insist(refs[number - 1].file === file && refs[number - 1].sourceDirectory === selected.directory, 'ambiguous-resume-local-chunk');
      continue;
    }
    core.insist(number === refs.length + 1, 'resume-chunk-gap');
    refs.push({ file, sourceDirectory: selected.directory, recorded: false });
  }
  core.insist(refs.length > 0, 'no-complete-resume-chunks');
  const index = { format: core.INDEX_FORMAT, createdAt: new Date().toISOString(), identity: structuredClone(adapter.identity), historyWarning: core.HISTORY_WARNING, scope: { ownerId, maxCandidates: maximum, chunkSize: 1000 }, inspected: 0, proposed: 0, nextAfterId: null, exhausted: false, chunks: [] };
  for (const ref of refs) {
    core.insist(!index.exhausted, 'resume-chunk-after-exhaustion');
    const source = await selectedDirectory(ref.sourceDirectory);
    const data = await readText(source, ref.file);
    const p = parse(data.text);
    const detail = validatePart(p, adapter, ownerId, index.nextAfterId);
    if (ref.recorded) core.insist(data.sha256 === ref.sha256 && detail.planDigest === ref.planDigest && detail.inspected === ref.inspected && detail.proposed === ref.proposed, 'resume-index-chunk-mismatch');
    index.chunks.push({ file: ref.file, sourceDirectory: source.directory, sha256: data.sha256, planDigest: detail.planDigest, inspected: detail.inspected, proposed: detail.proposed });
    index.inspected += detail.inspected; index.proposed += detail.proposed;
    core.insist(Number.isSafeInteger(index.inspected) && Number.isSafeInteger(index.proposed) && (maximum === null || index.inspected <= maximum), 'resume-total-bound-exceeded');
    index.nextAfterId = detail.nextAfterId; index.exhausted = detail.exhausted;
    if (checkpoint && index.chunks.length === checkpoint.chunks.length) {
      const sameContinuation = index.exhausted === checkpoint.exhausted && index.nextAfterId === checkpoint.nextAfterId;
      // An uncapped producer can record its final zero-row probe only in the
      // index. Retain the last part's cursor so planning repeats that DB-only
      // probe; the old terminal flag must not hide newly arrived candidates.
      const terminalProbe = checkpoint.scope.maxCandidates === null && checkpoint.exhausted === true && checkpoint.nextAfterId === null && index.exhausted === false && index.nextAfterId !== null && p.inspected === p.scope.limit;
      core.insist(index.inspected === checkpoint.inspected && index.proposed === checkpoint.proposed && (sameContinuation || terminalProbe) && (checkpoint.scope.maxCandidates === null || index.inspected <= checkpoint.scope.maxCandidates), 'resume-index-count-or-cursor-mismatch');
    }
  }
  // Recheck every source before returning a usable seed. Apply reads them again.
  for (const chunk of index.chunks) await readResumeChunk(chunk, { directory: selected.directory });
  await checkDirectory(selected);
  const finalNames = await fs.readdir(selected.directory);
  if (!checkpoint) core.insist(core.same(localParts.slice().sort(), finalNames.filter(name => name.startsWith('plan.json.part-')).sort()), 'resume-directory-changed');
  if (checkpointSha256 !== null) core.insist((await readText(selected, 'plan.json')).sha256 === checkpointSha256, 'resume-index-changed');
  else core.insist(!finalNames.includes('plan.json'), 'resume-index-changed');
  return index;
}
module.exports = { prepareResume, isCompatiblePlanIdentity, readResumeChunk, KNOWN_TOOL_HASHES };
