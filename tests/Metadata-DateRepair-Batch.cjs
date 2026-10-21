'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const core = require('../runtime/metadata-date-repair/core.cjs');

async function testBatch(req, temporary, reader) {
  req('reflect-metadata');
  const { MetadataRepository } = req('./dist/repositories/metadata.repository.js');
  let warnings = 0;
  const logger = { setContext() {}, verbose() {}, debug() {}, log() {}, warn() { warnings++; }, error() { warnings++; } };
  const repository = new MetadataRepository(logger);
  repository.setMaxConcurrency(1);
  const normalized = file => process.platform === 'win32' ? path.resolve(file).toLowerCase() : path.resolve(file);
  const directory = await fs.mkdtemp(path.join(temporary, 'metadata-batch-'));
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=', 'base64');
  const files = Array.from({ length: 25 }, (_, i) => path.join(directory, `fixture-${String(i).padStart(2, '0')}.png`));
  const keys = ['MIMEType', ...core.CAPTURE_TAGS, ...core.ZONE_TAGS, ...core.MOTION_TAGS];
  const evidence = tags => JSON.stringify(Object.fromEntries(keys.filter(key => tags[key] !== undefined).map(key => [key, tags[key]])));
  try {
    for (const file of files) await fs.writeFile(file, png);
    await repository.writeTags(files[0], { DateTimeOriginal: '2024:05:01 12:34:56' });
    await repository.writeTags(files[1], { DateTimeOriginal: '2024:05:01 12:34:56', OffsetTimeOriginal: '+09:00' });
    const before = new Map();
    for (const file of files) before.set(file, await fs.readFile(file));
    const expected = new Map();
    const singleStart = performance.now();
    for (const file of files) expected.set(file, evidence(await repository.readTags(file)));
    const singleMs = performance.now() - singleStart;
    const read = reader(req, repository, normalized);
    const batchStart = performance.now();
    const result = await read([...files].reverse());
    const batchMs = performance.now() - batchStart;
    assert.equal(result.size, files.length);
    assert.equal(warnings, 0);
    for (const file of files) {
      const metadata = result.get(file);
      assert(!(metadata instanceof Error));
      assert.equal(metadata.canonicalSourcePath, normalized(file));
      assert.equal(evidence(metadata.tags), expected.get(file));
      assert.deepEqual(await fs.readFile(file), before.get(file));
    }
    const duplicate = await read([files[0], files[0]]);
    assert.equal(duplicate.size, 1);
    assert.equal(evidence(duplicate.get(files[0]).tags), expected.get(files[0]));
    process.stdout.write(`PASS actual ExifTool batch: 25 files, same Immich date/zone parser, source bytes unchanged; single=${Math.round(singleMs)}ms batch=${Math.round(batchMs)}ms.\n`);
  } finally {
    await repository.teardown();
    await fs.rm(directory, { recursive: true });
  }
}
module.exports = { testBatch };
if (require.main === module) {
  const { createRequire } = require('node:module');
  const req = createRequire(path.resolve(process.argv[2], 'package.json'));
  testBatch(req, path.resolve(process.argv[3]), require('../runtime/metadata-date-repair/metadata-batch.cjs').reader).catch(error => {
    process.stderr.write(String(error.stack) + '\n'); process.exitCode = 1;
  });
}
