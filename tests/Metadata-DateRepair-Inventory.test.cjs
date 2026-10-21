'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { deflateSync } = require('node:zlib');
const { openInventory, MAX_BYTES } = require('../runtime/metadata-date-repair/inventory.cjs');
const record = () => ({ id: 'asset-one', ownerId: 'owner-one', file: '/synthetic/source.png', stat: { ino:'1',size:'42',mtimeNs:'2',ctimeNs:'3' }, extraction:'reader-one',raw: { SourceFile:'/synthetic/source.png',MIMEType:'image/png',DateTimeOriginal:'2024:05:01 12:34:56' } });
async function fixture(fn) {
  const directory=await fs.mkdtemp(path.join(await fs.realpath(os.tmpdir()),'metadata-inventory-'));
  try { await fn(path.join(directory,'inventory.sqlite')); } finally { await fs.rm(directory,{recursive:true}); }
}
test('unchanged source evidence survives close/reopen without an original read',async()=>fixture(async file=>{
  let inventory=await openInventory(file); inventory.put([record()]); inventory.close();
  inventory=await openInventory(file); try { assert.deepEqual(inventory.get(record()),record().raw); } finally { inventory.close(); }
}));
for(const field of ['ownerId','file','extraction','stat']) test(`changed ${field} requires a new source read`,async()=>fixture(async file=>{
  const inventory=await openInventory(file);
  try { inventory.put([record()]); const changed={...record(),[field]:field==='stat'?{...record().stat,ctimeNs:'changed'}:'changed'}; assert.equal(inventory.get(changed),null); } finally { inventory.close(); }
}));
test('repeated audits overwrite per-image records and per-owner progress',async()=>fixture(async file=>{
  const inventory=await openInventory(file), r=record();
  try {
    for(let i=0;i<50;i++) {
      inventory.put([{...r,raw:{...r.raw,DateTimeOriginal:String(i)}}]);
      inventory.inspected([{snapshot:{asset:{id:r.id,ownerId:r.ownerId,originalPath:r.file}},reason:i?'no-wall-clock-change':null,after:i?null:{localDateTime:'2024-05-01T12:34:56.000Z'}}]);
      inventory.progress(r.ownerId,{timezone:'Asia/Tokyo',upstreamCommit:'fixed'},{status:'scanning',cursor:String(i),inspected:i,proposed:0});
    }
  } finally { inventory.close(); }
  const { DatabaseSync }=require('node:sqlite'), db=new DatabaseSync(file);
  try {
    assert.equal(db.prepare('SELECT count(*) AS n FROM source').get().n,1);
    assert.equal(db.prepare('SELECT count(*) AS n FROM progress').get().n,1);
    assert.equal(db.prepare('SELECT cursor FROM progress').get().cursor,'49');
    assert.equal(db.prepare('SELECT outcome FROM source').get().outcome,'no-wall-clock-change');
  } finally { db.close(); }
  assert((await fs.stat(file)).size<128*1024);
}));
test('corrupted metadata cannot silently become repair evidence',async()=>fixture(async file=>{
  let inventory=await openInventory(file); inventory.put([record()]); inventory.close();
  const { DatabaseSync }=require('node:sqlite'), db=new DatabaseSync(file);
  db.prepare('UPDATE source SET raw=?').run(deflateSync(Buffer.from(JSON.stringify({...record().raw,DateTimeOriginal:'wrong'})))); db.close();
  inventory=await openInventory(file);
  try { assert.throws(()=>inventory.get(record()),error=>error.code==='inventory-metadata-digest-mismatch'); } finally { inventory.close(); }
}));
test('oversized metadata preserves the inspection record without an unbounded payload',async()=>fixture(async file=>{
  const inventory=await openInventory(file);
  try { inventory.put([{...record(),raw:{...record().raw,large:'x'.repeat(4*1024*1024)}}]); assert.equal(inventory.get(record()),null); } finally { inventory.close(); }
  assert((await fs.stat(file)).size<128*1024);
}));
test('SQLite growth has a fixed maximum and unrelated databases are refused',async()=>fixture(async file=>{
  const inventory=await openInventory(file);
  try { assert.equal(inventory.summary().capacityBytes,MAX_BYTES); } finally { inventory.close(); }
  const { DatabaseSync }=require('node:sqlite');
  const other=file+'.other'; const foreign=new DatabaseSync(other); foreign.exec('CREATE TABLE unrelated(value)'); foreign.close();
  await assert.rejects(openInventory(other),error=>error.code==='foreign-inventory-file');
}));
test('hard-linked inventories are refused',async()=>fixture(async file=>{
  const inventory=await openInventory(file); inventory.close(); await fs.link(file,file+'.link');
  await assert.rejects(openInventory(file),error=>error.code==='unsafe-inventory-file');
}));
