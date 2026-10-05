'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const core = require('../runtime/metadata-date-repair/core.cjs');
const { parse, fileJournal, readJournal, exclusive } = require('../runtime/metadata-date-repair/cli.cjs');
const ID = n => '00000000-0000-4000-8000-' + String(n).padStart(12,'0');
const OWNER = ID(900), INSTANT = '2024-05-01T03:04:05.678Z', LOCAL = '2024-05-01T12:04:05.678Z';
function snapshot(n = 1) { return { asset: { id: ID(n), ownerId: OWNER, originalPath: `/synthetic/${n}.png`, fileCreatedAt: INSTANT, localDateTime: INSTANT, fileModifiedAt: INSTANT, updatedAt: '2026-10-05T06:00:00.123456Z', updateId: ID(100+n), isEdited: false, isOffline: false, isExternal: false, deletedAt: null, type: 'IMAGE', livePhotoVideoId: null }, exif: { assetId: ID(n), dateTimeOriginal: INSTANT, timeZone: null, lockedProperties: [], updatedAt: '2026-10-05T06:00:00.654321Z', updateId: ID(200+n) }, sidecars: [], reverseLiveLinks: 0 }; }
function fake(count = 1) {
  let rows = new Map(Array.from({ length: count }, (_,i) => { const s = snapshot(i+1); return [s.asset.id,s]; }));
  const calls = [], events = []; let sequence = 300;
  const adapter = {
    identity: { upstreamCommit: 'synthetic', timezone: 'Asia/Tokyo' }, calls, events,
    get rows() { return rows; },
    async candidates(o) { calls.push(o); return [...rows.values()].filter(s => s.asset.ownerId === o.ownerId && (!o.afterId || s.asset.id > o.afterId)).slice(0,o.limit).map(v=>structuredClone(v)); },
    async snapshot(id) { return structuredClone(rows.get(id)); },
    async snapshots(ids) { return ids.filter(id => rows.has(id)).map(id => structuredClone(rows.get(id))); },
    async sidecarsAbsent() { events.push('sidecar'); return true; },
    async stat() { events.push('stat'); return { token: { size:'42', mtimeNs:'1', ctimeNs:'2', birthtimeNs:'3', ino:'4' }, stats: { birthtimeMs: Date.parse(INSTANT), mtimeMs: Date.parse(INSTANT)+1000, mtime: new Date(Date.parse(INSTANT)+1000) } }; },
    async readMetadata(p) { events.push('metadata'); return { canonicalSourcePath: p, tags: { SourceFile: p, MIMEType:'image/png' } }; },
    firstDateTime: tags => tags.DateTimeOriginal && !tags.DateTimeOriginal.startsWith('invalid') ? {} : undefined,
    getDates: () => ({ dateTimeOriginal: INSTANT, localDateTime: LOCAL, timeZone:'Asia/Tokyo' }),
    metadataEvidence: tags => ({ MIMEType: tags.MIMEType }),
    async transaction(fn) {
      const backup = structuredClone(rows); events.push('begin');
      try {
        const result = await fn({
          async snapshotForUpdate(id) { events.push('lock'); return structuredClone(rows.get(id)); },
          async updateDates(before, after) {
            events.push('asset-update'); rows.get(before.asset.id).asset.localDateTime = after.localDateTime;
            if (adapter.failExifCas) throw new core.Stop('exif-cas-failed');
            const s = rows.get(before.asset.id); s.exif.timeZone = after.timeZone;
            s.asset.updateId=ID(sequence++); s.exif.updateId=ID(sequence++);
            s.asset.updatedAt='2026-10-05T06:10:00.123456Z'; s.exif.updatedAt='2026-10-05T06:10:00.123456Z';
            events.push('exif-update'); return structuredClone(s);
          },
        });
        events.push('commit'); return result;
      } catch(e) { rows=backup; events.push('rollback'); throw e; }
    },
  };
  return adapter;
}
function journal(events = [], failKind) { const records=[]; return { records, async header(r) { records.push(r); events.push('header-fsync'); }, async appendSync(r) { if (r.kind === failKind) throw new Error('synthetic disk failure'); records.push(r); events.push(r.kind+'-fsync'); } }; }
const options = { ownerId:OWNER, limit:100, pageSize:2 };
async function prepared(adapter = fake()) { const p = await core.plan(adapter, options); return { adapter,p,approved:{approvedDigest:core.hash(p),acknowledgeHistoryAmbiguity:true} }; }
async function rejectsCode(fn, code) { await assert.rejects(fn, e => e.code === code); }

test('runtime adapter imports without starting the server', () => { const runtime = require('../runtime/metadata-date-repair/runtime.cjs'); assert.equal(typeof runtime.createAdapter, 'function'); });
test('default command is plan, unknown and duplicate options fail closed', () => { assert.equal(parse([]).command,'plan'); assert.throws(()=>parse(['--apply'])); assert.throws(()=>parse(['plan','--limit','1','--limit','2'])); });
test('plan is bounded, keyset-paged, read-only, with honest continuation', async () => { const a=fake(5), p=await core.plan(a,{...options,limit:3}); assert.equal(p.entries.length,3); assert.equal(p.inspected,3); assert.equal(p.exhausted,false); assert.equal(p.nextAfterId,ID(3)); assert.deepEqual(a.calls.map(v=>v.limit),[2,1]); assert.equal(a.events.includes('begin'),false); });
test('empty candidate scope reports exhaustion without claiming entire library',async()=>{ const a=fake(0),p=await core.plan(a,options); assert.equal(p.exhausted,true); assert.equal(p.scope.ownerId,OWNER); });
test('successful apply updates only date wall time and zone; durable WAL precedes commit',async()=>{ const {adapter:a,p,approved}=await prepared();const j=journal(a.events);const ids=await core.apply(a,p,approved,j);assert.deepEqual(ids,[ID(1)]);assert.equal(a.rows.get(ID(1)).asset.fileCreatedAt,INSTANT);assert.equal(a.rows.get(ID(1)).exif.dateTimeOriginal,INSTANT);assert.equal(a.rows.get(ID(1)).asset.localDateTime,LOCAL);assert(a.events.indexOf('prepared-fsync')<a.events.indexOf('commit'));assert(a.events.indexOf('metadata')<a.events.indexOf('begin'));const b=a.events.lastIndexOf('lock');assert(a.events.slice(b,b+4).includes('stat')); });
test('apply requires explicit history acknowledgement before any journal or transaction',async()=>{ const {adapter:a,p,approved}=await prepared();const j=journal();await rejectsCode(()=>core.apply(a,p,{...approved,acknowledgeHistoryAmbiguity:false},j),'historical-ambiguity-not-acknowledged');assert.equal(j.records.length,0);assert(!a.events.includes('begin')); });
test('wrong digest and runtime fail before a mutation',async()=>{ const {adapter:a,p,approved}=await prepared();await rejectsCode(()=>core.apply(a,p,{...approved,approvedDigest:'0'.repeat(64)},journal()),'plan-digest-not-approved');a.identity.timezone='UTC';await rejectsCode(()=>core.apply(a,p,approved,journal()),'runtime-or-timezone-changed'); });
test('stale snapshot preserves newer manual changes',async()=>{ const {adapter:a,p,approved}=await prepared();a.rows.get(ID(1)).exif.lockedProperties=['dateTimeOriginal'];await rejectsCode(()=>core.apply(a,p,approved,journal()),'stale-plan');assert(!a.events.includes('begin')); });
test('changed snapshot after source read is caught under row lock',async()=>{ const {adapter:a,p,approved}=await prepared();const read=a.readMetadata;a.readMetadata=async p=>{const result=await read(p);a.rows.get(ID(1)).asset.updateId=ID(700);return result;};await rejectsCode(()=>core.apply(a,p,approved,journal()),'transaction-snapshot-changed');assert(a.events.includes('rollback')); });
test('second-row CAS failure rolls back first-row update',async()=>{ const {adapter:a,p,approved}=await prepared();const original=structuredClone(a.rows);a.failExifCas=true;await rejectsCode(()=>core.apply(a,p,approved,journal()),'exif-cas-failed');assert.deepEqual(a.rows,original); });
test('write-ahead journal fsync failure rolls back both date updates',async()=>{ const {adapter:a,p,approved}=await prepared();const original=structuredClone(a.rows);await assert.rejects(()=>core.apply(a,p,approved,journal(a.events,'prepared')));assert.deepEqual(a.rows,original);assert(!a.events.includes('commit')); });
test('postcommit journal failure is not retried and can be reconciled read-only',async()=>{ const {adapter:a,p,approved}=await prepared();const j=journal(a.events,'committed');await assert.rejects(()=>core.apply(a,p,approved,j));assert.equal(a.rows.get(ID(1)).asset.localDateTime,LOCAL);assert.equal(a.events.filter(v=>v==='commit').length,1);assert.deepEqual(await core.reconcile(a,j.records),[{id:ID(1),state:'applied-unchanged'}]); });
test('rollback after prepared WAL reconciles as not applied',async()=>{ const {adapter:a,p,approved}=await prepared();const original=a.transaction;a.transaction=fn=>original(async tx=>{await fn(tx);throw new Error('synthetic commit failed');});const j=journal();await assert.rejects(()=>core.apply(a,p,approved,j));assert.deepEqual(await core.reconcile(a,j.records),[{id:ID(1),state:'not-applied-unchanged'}]); });
test('normal rerun cannot accumulate offset',async()=>{const {adapter:a,p,approved}=await prepared();await core.apply(a,p,approved,journal());await rejectsCode(()=>core.apply(a,p,approved,journal()),'stale-plan');const next=await core.plan(a,options);assert.equal(next.entries.length,0);});
test('undo restores two fields only when both resulting revisions still match',async()=>{const {adapter:a,p,approved}=await prepared();const j=journal();await core.apply(a,p,approved,j);await core.undo(a,p,j.records,{...approved,approvedJournalDigest:core.hash(j.records)},journal());assert.equal(a.rows.get(ID(1)).asset.localDateTime,INSTANT);assert.equal(a.rows.get(ID(1)).exif.timeZone,null);assert.equal(a.rows.get(ID(1)).asset.fileCreatedAt,INSTANT);});
test('undo refuses newer manual revision and preserves it',async()=>{const {adapter:a,p,approved}=await prepared();const j=journal();await core.apply(a,p,approved,j);a.rows.get(ID(1)).exif.updateId=ID(801);const original=structuredClone(a.rows);await rejectsCode(()=>core.undo(a,p,j.records,{...approved,approvedJournalDigest:core.hash(j.records)},journal()),'undo-state-changed-or-not-applied');assert.deepEqual(a.rows,original);});
test('undo journal mixup is rejected',async()=>{const {adapter:a,p,approved}=await prepared();await rejectsCode(()=>core.undo(a,p,[],{...approved,approvedJournalDigest:'0'.repeat(64)},journal()),'journal-digest-not-approved');});
for(const [name,change,reason] of [
 ['parseable timestamp without timezone',t=>t.DateTimeOriginal='2024:05:01 12:00:00','capture-date-present'],
 ['invalid nonempty timestamp',t=>t.DateTimeOriginal='invalid timestamp','unparsed-capture-date-present'],
 ['explicit timezone',t=>t.zone='Asia/Tokyo','source-timezone-present'],
 ['reader warning',t=>t.Warning='bad metadata','metadata-warning'],
 ['motion photo',t=>t.MotionPhoto=1,'motion-or-live-metadata'],
 ['embedded video',t=>t.EmbeddedVideoType='MotionPhoto_Data','motion-or-live-metadata'],
]) test(`source gate excludes ${name}`,async()=>{const a=fake();const read=a.readMetadata;a.readMetadata=async p=>{const r=await read(p);change(r.tags);return r;};const p=await core.plan(a,options);assert.equal(p.entries.length,0);assert.equal(p.excluded[0].reason,reason);});
test('unanchored earlier database instant is excluded without relaxed apply flag',async()=>{const a=fake();const stat=a.stat;a.stat=async p=>{const r=await stat(p);r.stats.birthtimeMs+=86400000;r.stats.mtimeMs+=86400000;return r;};const p=await core.plan(a,options);assert.equal(p.excluded[0].reason,'stored-instant-not-filesystem-anchored');});
test('actual fallback instant change is excluded',async()=>{const a=fake();a.getDates=()=>({dateTimeOriginal:'2020-01-01T00:00:00.000Z',localDateTime:LOCAL,timeZone:'Asia/Tokyo'});const p=await core.plan(a,options);assert.equal(p.excluded[0].reason,'fallback-instant-differs');});
test('sidecar discovered immediately before write aborts',async()=>{const {adapter:a,p,approved}=await prepared();let checks=0;a.sidecarsAbsent=async()=>++checks<3;await rejectsCode(()=>core.apply(a,p,approved,journal()),'sibling-sidecar');assert.equal(a.rows.get(ID(1)).exif.timeZone,null);});
test('source changing during metadata read is excluded',async()=>{const a=fake();let calls=0;const stat=a.stat;a.stat=async p=>{const r=await stat(p);r.token.size=String(calls++);return r;};const p=await core.plan(a,options);assert.equal(p.excluded[0].reason,'source-changed-during-read');});
test('duplicate and out-of-order candidate pages fail closed',async()=>{const a=fake();a.candidates=async()=>[snapshot(),snapshot()];await rejectsCode(()=>core.plan(a,options),'invalid-keyset-order');});
test('journal uses exclusive text output, fsynced complete lines, tolerates truncated final line for reconciliation',async()=>{const dir=await fs.mkdtemp(path.join(os.tmpdir(),'date-repair-synthetic-'));try{const p=path.join(dir,'journal.jsonl'),h=await exclusive(p,'.jsonl');const j=fileJournal(h);await j.header({format:core.FORMAT,operation:'apply'});await j.appendSync({kind:'prepared',id:ID(1)});await h.close();await assert.rejects(()=>exclusive(p,'.jsonl'));await fs.appendFile(p,'{"kind":');const r=await readJournal(p);assert.equal(r.truncatedTail,true);assert.equal(r.records.length,2);}finally{await fs.rm(dir,{recursive:true});}});

test('apply and undo reject misleading plan-only safety limits',()=>{for(const command of ['apply','undo','reconcile']) assert.throws(()=>parse([command,'--limit','1']),e=>e.code==='option-not-valid-for-command');});
test('plan-all automatically chunks a bounded scan and apply-all uses one exact index approval',async()=>{const a=fake(1002),chunks=new Map();const index=await core.planAll(a,{ownerId:OWNER,maxCandidates:1002,pageSize:100},async(p,n)=>{const file=String(n);chunks.set(file,structuredClone(p));return{file,sha256:'synthetic'};});assert.equal(index.chunks.length,2);assert.equal(index.inspected,1002);assert.equal(index.exhausted,false);const done=await core.applyAll(a,index,{ownerId:OWNER,approvedIndexDigest:core.hash(index),acknowledgeHistoryAmbiguity:true},async c=>structuredClone(chunks.get(c.file)),async()=>({...journal(),async close(){}}));assert.equal(done,1002);});
test('apply-all validates all chunk digests before any mutation',async()=>{const a=fake(),chunks=new Map();const index=await core.planAll(a,{ownerId:OWNER,maxCandidates:1,pageSize:1},async(p,n)=>{chunks.set(String(n),p);return{file:String(n),sha256:'synthetic'};});chunks.get('1').entries[0].after.localDateTime='2000-01-01T00:00:00.000Z';await rejectsCode(()=>core.applyAll(a,index,{ownerId:OWNER,approvedIndexDigest:core.hash(index),acknowledgeHistoryAmbiguity:true},async c=>chunks.get(c.file),async()=>({...journal(),async close(){}})),'plan-digest-not-approved');assert(!a.events.includes('begin'));});
test('apply-all stops without retrying an uncertain chunk',async()=>{const a=fake(),chunks=new Map();const index=await core.planAll(a,{ownerId:OWNER,maxCandidates:1,pageSize:1},async(p,n)=>{chunks.set(String(n),p);return{file:String(n),sha256:'synthetic'};});let closed=0;await assert.rejects(()=>core.applyAll(a,index,{ownerId:OWNER,approvedIndexDigest:core.hash(index),acknowledgeHistoryAmbiguity:true},async c=>chunks.get(c.file),async()=>({...journal(a.events,'committed'),async close(){closed++;}})));assert.equal(closed,1);assert.equal(a.events.filter(e=>e==='commit').length,1);});
