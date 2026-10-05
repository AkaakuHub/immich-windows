'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const core = require('../runtime/metadata-date-repair/core.cjs');
const runtime = require('../runtime/metadata-date-repair/runtime.cjs');
const cli = require('../runtime/metadata-date-repair/cli.cjs');
const guided = require('../runtime/metadata-date-repair/guided.cjs');
const ID = n => `00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const owner = ID(999), instant = '2024-01-01T01:00:00.000Z';
const failure = code => Object.assign(new Error('SECRET raw SQL password C:\\private\\photo.png'), { code, query: 'SECRET', parameters: ['SECRET'] });
async function temporary(t) { const p = await fs.mkdtemp(path.join(os.tmpdir(), 'repair-diagnostic-')); t.after(() => fs.rm(p, { recursive:true, force:true })); return p; }
function row(id) { return { asset: { id, ownerId:owner, originalPath:id+'.png', fileCreatedAt:instant, localDateTime:instant, fileModifiedAt:instant, updatedAt:instant, updateId:ID(200), isEdited:false, isOffline:false, deletedAt:null, type:'IMAGE', livePhotoVideoId:null }, exif: { assetId:id, dateTimeOriginal:instant, timeZone:null, updatedAt:instant, updateId:ID(201), lockedProperties:[] }, sidecars:[], reverseLiveLinks:0 }; }
for (const [code, reason] of [['ENOENT','source-file-missing'],['ENOTDIR','source-file-missing'],['EACCES','source-file-inaccessible'],['EPERM','source-file-inaccessible']]) test(`known ${code} source failure is an explicit exclusion without writes`, async () => {
  let reads=0, writes=0;
  const adapter={ identity:{timezone:'Asia/Tokyo'}, async candidates(){return [row(ID(1))];}, async stat(){throw runtime.sourceFileError(failure(code));}, async readMetadata(){reads++;}, async transaction(){writes++;} };
  const plan=await core.plan(adapter,{ownerId:owner,limit:1000,pageSize:25});
  assert.deepEqual(plan.excluded,[{id:ID(1),reason}]); assert.equal(plan.entries.length,0); assert.equal(reads,0); assert.equal(writes,0);
});
test('unexpected source I/O stops with exact stage and asset instead of being excluded', async () => {
  const original=failure('EIO');
  const adapter={identity:{},async candidates(){return [row(ID(2))];},async stat(){throw runtime.sourceFileError(original);}};
  await assert.rejects(core.plan(adapter,{ownerId:owner,limit:1000,pageSize:25}),error=>error===original);
  const details=core.failureDetails(original); assert.equal(details.phase,'source-stat-before');assert.equal(details.code,'EIO');assert.equal(details.assetId,ID(2));assert(!JSON.stringify(details).includes('SECRET'));
});
test('failure fields are allowlisted and location has no raw path', () => {
  const error=failure('57014');error.repairContext={phase:'candidate-query',cursor:ID(2)};error.stack='Error: SECRET\n    at f (C:\\private\\core.cjs:99:4)';
  const details=core.failureDetails(error);assert.deepEqual(details.location,{module:'core.cjs',line:99,column:4});assert.equal(details.code,'57014');assert.equal(details.cursor,ID(2));assert(!JSON.stringify(details).includes('private'));assert(!JSON.stringify(details).includes('SECRET'));
  error.code='SECRET';assert.equal(core.failureDetails(error).code,'UNKNOWN');
});
test('database timeout is logged durably before cleanup and cleanup cannot replace it', async t => {
  const root=await temporary(t), events=[], original=failure('57014'), closing=failure('ECONNRESET');
  const prior=runtime.createAdapter;
  runtime.createAdapter=async()=>({identity:{timezone:'Asia/Tokyo'},async candidates(){throw original;},async close(){events.push('close');assert.equal(JSON.parse(await fs.readFile(path.join(root,'failure.json'),'utf8')).code,'57014');throw closing;}});
  try {
    await assert.rejects(cli.run(['plan-all','--release-root',root,'--owner-id',owner,'--expected-timezone','Asia/Tokyo','--out',path.join(root,'plan.json')],{emit(){},async onFailure(error,options={}){events.push(options.cleanup?'cleanup-log':'primary-log');await cli.persistFailure(root,core.failureDetails(error),options);}}),error=>error===original);
  } finally {runtime.createAdapter=prior;}
  assert.deepEqual(events,['primary-log','close','cleanup-log']);
  const primary=JSON.parse(await fs.readFile(path.join(root,'failure.json'),'utf8')), cleanup=JSON.parse(await fs.readFile(path.join(root,'failure-cleanup.json'),'utf8'));
  assert.equal(primary.phase,'candidate-query');assert.equal(primary.code,'57014');assert.equal(cleanup.code,'ECONNRESET');assert(!JSON.stringify([primary,cleanup]).includes('SECRET'));
});
test('checkpoint disk-full leaves previous index intact and does not advance it', async t => {
  const root=await temporary(t), file=path.join(root,'plan.json'), original=failure('ENOSPC');await fs.writeFile(file,'previous');
  await assert.rejects(core.atStage('checkpoint-write',()=>cli.writeCheckpoint(file,{inspected:1000},{...fs,async rename(){throw original;}})),error=>error===original);
  assert.equal(await fs.readFile(file,'utf8'),'previous');assert.equal(core.failureDetails(original).phase,'checkpoint-write');assert.equal(core.failureDetails(original).code,'ENOSPC');
});
test('log-write failure preserves its primary write error even when close also fails', async () => {
  const original=failure('ENOSPC');let closed=0;
  await assert.rejects(cli.persistFailure('/synthetic',{}, {fileSystem:{async open(){return {async writeFile(){throw original;},async sync(){assert.fail('no sync after failed write');},async close(){closed++;throw failure('EIO');}};}}}),error=>error===original);assert.equal(closed,1);
});
test('guided failure reports both safe primary and log failure and never retries planning', async t => {
  const root=await temporary(t), lines=[], original=failure('57014');original.repairContext={phase:'candidate-query'};let calls=0, asks=0;
  const io={write(line){lines.push(line);},async ask(){asks++;return '1';}};
  await assert.rejects(guided.runGuided({releaseRoot:root,outputRoot:path.join(root,'private')},io,{async createAdapter(){return {identity:{timezone:'Asia/Tokyo'},async listUsers(){return [{id:owner,name:'Fixture',email:'fixture@example.invalid'}];},async close(){}};},async run(args,hooks){calls++;await hooks.onFailure(original);throw original;},async persistFailure(){throw failure('ENOSPC');}}),error=>error===original);
  assert.equal(calls,1);assert.equal(asks,1);const text=lines.join('\n');assert(text.includes('candidate-query / 57014'));assert(text.includes('Could not save the error log: ENOSPC'));assert(!text.includes('SECRET'));assert(!text.includes('Repair completed'));
});
