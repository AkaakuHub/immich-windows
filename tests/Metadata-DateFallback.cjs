// Execute the actual prepared getDates method with synthetic dates, no media,
// database, network, or service access. Luxon is the existing server dependency.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire, stripTypeScriptTypes } = require('node:module');
const { spawnSync } = require('node:child_process');

const sourceRoot = process.argv[2];
const serverIndex = process.argv.indexOf('--server-root');
const baselineIndex = process.argv.indexOf('--baseline-source');
assert(sourceRoot && serverIndex >= 0, 'Usage: node tests/Metadata-DateFallback.cjs SOURCE --server-root SERVER [--baseline-source SOURCE]');
assert.equal(typeof stripTypeScriptTypes, 'function', 'Node >=22.13 is required (package pins Node 24)');
const { DateTime, Settings } = createRequire(path.resolve(process.argv[serverIndex + 1], 'package.json'))('luxon');
const relativeSource = 'server/src/services/metadata.service.ts';
const source = fs.readFileSync(path.join(sourceRoot, relativeSource), 'utf8');
let baseline;
if (baselineIndex >= 0) {
  baseline = fs.readFileSync(path.join(process.argv[baselineIndex + 1], relativeSource), 'utf8');
} else {
  const result = spawnSync('git', ['-C', sourceRoot, 'show', `HEAD:${relativeSource}`], { encoding: 'utf8' });
  assert.equal(result.status, 0, `Cannot read pinned baseline: ${result.stderr}`);
  baseline = result.stdout;
}

function getDatesMethod(text) {
  // Git checkout may use CRLF on Windows; git show returns the stored LF bytes.
  text = text.replaceAll('\r\n', '\n');
  const begin = text.indexOf('  private getDates(');
  assert(begin >= 0, 'Missing getDates method');
  const end = text.indexOf('\n  }', begin);
  assert(end > begin, 'Unclosed getDates method');
  return text.slice(begin, end + 4);
}
function probe(text) {
  const code = stripTypeScriptTypes(`class Probe {\n${getDatesMethod(text)}\n}`);
  // firstDateTime and EXIF parsing are unchanged. Synthetic parsed EXIF values
  // isolate date conversion without reading any image or spawning ExifTool.
  const Type = new Function('DateTime', 'firstDateTime', `return ${code}`)(DateTime, (tags) => tags.capture);
  const service = new Type();
  service.logger = { debug() {}, verbose() {} };
  return service;
}
const patched = probe(source);
const original = probe(baseline);
const fallbackMarker = '    if (!localDateTime || !dateTimeOriginal) {';
assert.equal(getDatesMethod(source).split(fallbackMarker)[0], getDatesMethod(baseline).split(fallbackMarker)[0], 'EXIF capture-date interpretation must be identical apart from line endings');
let checks = 0;
const savedTZ = process.env.TZ;
const savedDefaultZone = Settings.defaultZone;
function useZone(zone) {
  process.env.TZ = zone;
  Settings.defaultZone = 'system';
  Settings.resetCaches();
}
function input(instant, extension = 'png', overrides = {}) {
  const millis = Date.parse(instant);
  return {
    asset: { id: 'synthetic', originalPath: `synthetic.${extension}`, fileCreatedAt: new Date(millis), ...overrides.asset },
    stats: { birthtimeMs: millis + 2000, mtimeMs: millis + 1000, mtime: new Date(millis + 1000), ...overrides.stats },
  };
}
function values(result) {
  return { dateTimeOriginal: result.dateTimeOriginal.toISOString(), localDateTime: result.localDateTime.toISOString(), timeZone: result.timeZone };
}
function fallback(label, runtimeZone, instant, expectedLocal, tags = {}, overrides = {}) {
  useZone(runtimeZone);
  for (const extension of ['png', 'jpg']) {
    const { asset, stats } = input(instant, extension, overrides);
    const result = patched.getDates(asset, tags, stats);
    const defaultDate = DateTime.fromMillis(Date.parse(instant));
    const expectedZone = defaultDate.setZone(tags.zone ?? defaultDate.zone).zoneName;
    assert.deepEqual(values(result), { dateTimeOriginal: instant, localDateTime: expectedLocal, timeZone: expectedZone }, `${label} (${extension})`);
    const displayed = DateTime.fromJSDate(result.dateTimeOriginal, { zone: result.timeZone }).setZone('UTC', { keepLocalTime: true }).toJSDate();
    assert.equal(displayed.toISOString(), result.localDateTime.toISOString(), `${label}: detail panel and local wall time agree`);
    const repeated = patched.getDates({ ...asset, fileCreatedAt: result.dateTimeOriginal, localDateTime: result.localDateTime }, tags, stats);
    assert.deepEqual(values(repeated), values(result), `${label}: repeated extraction must not accumulate an offset`);
    checks++;
  }
}
try {
  fallback('Tokyo', 'Asia/Tokyo', '2024-05-01T03:04:05.678Z', '2024-05-01T12:04:05.678Z');
  fallback('Tokyo date rollover', 'Asia/Tokyo', '2024-05-01T19:00:00.000Z', '2024-05-02T04:00:00.000Z');
  fallback('UTC', 'UTC', '2024-05-01T03:04:05.678Z', '2024-05-01T03:04:05.678Z');
  fallback('New York winter', 'America/New_York', '2024-01-15T12:00:00.000Z', '2024-01-15T07:00:00.000Z');
  fallback('New York summer', 'America/New_York', '2024-07-15T12:00:00.000Z', '2024-07-15T08:00:00.000Z');
  fallback('Before spring transition', 'America/New_York', '2024-03-10T06:59:59.000Z', '2024-03-10T01:59:59.000Z');
  fallback('After spring transition', 'America/New_York', '2024-03-10T07:00:00.000Z', '2024-03-10T03:00:00.000Z');
  fallback('Before autumn transition', 'America/New_York', '2024-11-03T05:59:59.000Z', '2024-11-03T01:59:59.000Z');
  fallback('After autumn transition', 'America/New_York', '2024-11-03T06:00:00.000Z', '2024-11-03T01:00:00.000Z');
  fallback('Fractional offset', 'Asia/Kathmandu', '2024-05-01T12:00:00.000Z', '2024-05-01T17:45:00.000Z');
  fallback('GPS zone wins over Tokyo runtime', 'Asia/Tokyo', '2024-07-15T12:00:00.000Z', '2024-07-15T08:00:00.000Z', { zone: 'America/New_York', zoneSource: 'GPSLatitude/GPSLongitude' });
  fallback('Explicit fixed offset normalized consistently', 'Asia/Tokyo', '2024-05-01T12:00:00.000Z', '2024-05-01T17:45:00.000Z', { zone: 'UTC+05:45' });
  fallback('Explicit UTC zone wins over Tokyo runtime', 'Asia/Tokyo', '2024-05-01T12:00:00.000Z', '2024-05-01T12:00:00.000Z', { zone: 'UTC' });
  fallback('Missing birthtime uses mtime', 'Asia/Tokyo', '2024-05-01T03:00:00.000Z', '2024-05-01T12:00:00.000Z', {}, {
    asset: { fileCreatedAt: new Date('2024-05-02T00:00:00.000Z') }, stats: { birthtimeMs: 0, mtimeMs: Date.parse('2024-05-01T03:00:00.000Z'), mtime: new Date('2024-05-01T03:00:00.000Z') },
  });
  fallback('Birthtime remains earliest', 'Asia/Tokyo', '2024-05-01T03:00:00.000Z', '2024-05-01T12:00:00.000Z', {}, {
    asset: { fileCreatedAt: new Date('2024-05-02T00:00:00.000Z') }, stats: { birthtimeMs: Date.parse('2024-05-01T03:00:00.000Z') },
  });
  for (const runtimeZone of ['UTC', 'Asia/Tokyo', 'America/New_York']) {
    useZone(runtimeZone);
    const { asset, stats } = input('2020-01-01T00:00:00.000Z');
    for (const [label, rawValue, hasZone, zone] of [
      ['camera explicit zone', '2024-05-01T12:00:00+09:00', true, 'Asia/Tokyo'],
      ['sidecar explicit zone', '2024-07-15T08:00:00-04:00', true, 'America/New_York'],
      ['explicit UTC suffix', '2024-05-01T12:00:00Z', true, undefined],
      ['capture date without zone', '2024-05-01T12:00:00', false, undefined],
      ['capture date with inferred GPS zone', '2024-05-01T12:00:00', false, 'Asia/Tokyo'],
    ]) {
      const tags = { zone, capture: { tag: 'DateTimeOriginal', dateTime: { rawValue, hasZone, toDateTime: () => DateTime.fromISO(rawValue, { setZone: true }) } } };
      assert.deepEqual(values(patched.getDates(asset, tags, stats)), values(original.getDates(asset, tags, stats)), `${label} unchanged under ${runtimeZone}`);
      checks++;
    }
  }
  useZone('Asia/Tokyo');
  const { asset, stats } = input('2024-05-01T03:00:00.000Z');
  assert.equal(original.getDates(asset, {}, stats).localDateTime.toISOString(), '2024-05-01T03:00:00.000Z', 'Baseline must reproduce the UTC wall-time bug');
  assert.equal(patched.getDates(asset, {}, stats).localDateTime.toISOString(), '2024-05-01T12:00:00.000Z', 'Patched Tokyo wall time must fix the baseline regression');
  checks++;
  console.log(`PASS metadata date fallback: ${checks} cases; actual getDates + Luxon, PNG/JPEG synthetic inputs, runtime/GPS zones, DST, EXIF/sidecar branch unchanged, repeated extraction stable.`);
} finally {
  if (savedTZ === undefined) delete process.env.TZ;
  else process.env.TZ = savedTZ;
  Settings.defaultZone = savedDefaultZone;
  Settings.resetCaches();
}
