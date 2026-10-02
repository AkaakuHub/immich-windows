// Execute the patched upstream method bodies, then emit/run PostgreSQL assertions
// for the SQL regex/LIKE expressions they actually build. No media or DB writes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire, stripTypeScriptTypes } = require('node:module');
const { spawnSync } = require('node:child_process');

assert.equal(typeof stripTypeScriptTypes, 'function', 'Node >=22.13 with stripTypeScriptTypes is required (package pins Node 24)');
const sourceRoot = process.argv[2];
assert(sourceRoot, 'Usage: node tests/Server-Portability.cjs SOURCE [--sql-output FILE] [--psql EXE] [--server-root DIR]');
const serverIndex = process.argv.indexOf('--server-root');
const picomatch = serverIndex >= 0 ? createRequire(path.resolve(process.argv[serverIndex + 1], 'package.json'))('picomatch') : null;
const sqlChecks = [];
let checks = 0;
const literal = (value) => value === null ? 'NULL' : `'${String(value).replaceAll("'", "''")}'`;
const expression = (sql) => ({ sql, as() { return this; } });
const column = (name) => expression(name.split('.').map((part) => `"${part}"`).join('.'));
const eb = (left, op, right) => Object.assign(expression(`${typeof left === 'string' ? column(left).sql : left.sql} ${op} ${literal(right)}`), { left, op, right });
eb.val = (value) => Object.assign(expression(literal(value)), { value });
eb.ref = column;
eb.fn = (name, args) => Object.assign(expression(`${name}(${args.map((arg) => typeof arg === 'string' ? column(arg).sql : arg.sql).join(', ')})`), { name, args });
eb.or = (items) => expression(items.length ? `(${items.map((item) => item.sql).join(' OR ')})` : 'FALSE');
eb.not = (item) => expression(`NOT (${item.sql})`);

function method(file, name) {
  const source = fs.readFileSync(path.join(sourceRoot, 'server/src', file), 'utf8');
  const match = new RegExp(`^  (?:private )?(?:async )?\\*?${name}\\(`, 'm').exec(source);
  assert(match, `Missing upstream method ${name}`);
  const end = source.indexOf('\n  }', match.index);
  assert(end > match.index, `Unclosed upstream method ${name}`);
  return source.slice(match.index, end + 4);
}
function probe(file, names, flavor, extra = {}) {
  const code = stripTypeScriptTypes(`class Probe {\n${names.map((name) => method(file, name)).join('\n')}\n}`);
  const env = {
    path: flavor, normalize: flavor.normalize, sep: flavor.sep,
    process: { platform: flavor === path.win32 ? 'win32' : 'linux' },
    AssetVisibility: { Timeline: 'timeline' }, asUuid: (value) => value, withExif: () => {},
    ...extra,
  };
  const Type = new Function(...Object.keys(env), `return ${code}`)(...Object.values(env));
  return new Type();
}
function database(rows = []) {
  const captured = { where: [], select: null, orderBy: null };
  const query = {
    selectFrom() { return this; }, updateTable() { return this; },
    select(value) { if (typeof value === 'function') captured.select = value(eb); return this; },
    selectAll() { return this; }, distinct() { return this; }, set() { return this; }, $call() { return this; },
    where(...args) {
      if (typeof args[0] === 'function') captured.where.push(args[0](eb));
      else if (args[0] === 'originalPath') captured.where.push(eb(...args));
      return this;
    },
    orderBy(value) { if (typeof value === 'function') captured.orderBy = value(eb); return this; },
    async execute() { return rows; }, async executeTakeFirstOrThrow() { return {}; },
  };
  return { query, captured };
}
function sqlCheck(label, assetPath, condition, expected) {
  sqlChecks.push(`IF (SELECT ${condition} FROM (VALUES (${literal(assetPath)})) AS asset("originalPath")) IS DISTINCT FROM ${expected ? 'TRUE' : 'FALSE'} THEN RAISE EXCEPTION '%', ${literal(label)}; END IF;`);
  checks++;
}

(async () => {
  for (const flavor of [path.win32, path.posix]) {
    const view = probe('repositories/view-repository.ts', ['getUniqueOriginalPaths', 'getAssetsByOriginalPath'], flavor);
    const cases = flavor === path.win32 ? [
      ['D:\\photo.jpg', 'D:\\', 'D:'],
      ['\\photo.jpg', '\\', ''],
      ['D:\\photos\\photo.jpg', 'D:\\photos\\', 'D:/photos'],
      ['\\\\host\\share\\photo.jpg', '\\\\host\\share\\', '//host/share'],
      ['D:\\100%_real\\photo.jpg', 'D:\\100%_real\\', 'D:/100%_real'],
    ] : [
      ['/photo.jpg', '/', ''],
      ['/photos/photo.jpg', '/photos/', '/photos'],
      ['/100%_real/photo.jpg', '/100%_real/', '/100%_real'],
      ['/photos\\literal/photo.jpg', '/photos\\literal/', '/photos\\literal'],
    ];
    for (const [assetPath, directoryPath, displayPath] of cases) {
      let db = database([{ directoryPath }]); view.db = db.query;
      assert.deepEqual(await view.getUniqueOriginalPaths('user'), [displayPath]);
      assert.equal(new RegExp(db.captured.select.args[1].value).exec(assetPath)?.[1], directoryPath);
      sqlCheck(`directory extraction: ${assetPath}`, assetPath, `${db.captured.select.sql} = ${literal(directoryPath)}`, true);
      db = database(); view.db = db.query;
      await view.getAssetsByOriginalPath('user', displayPath);
      const escapedDirectory = directoryPath.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
      assert.equal(db.captured.where[0].right, `%${escapedDirectory}%`);
      assert.equal(db.captured.where[1].right, `%${escapedDirectory}%${flavor.sep === '\\' ? '\\\\' : '/'}%`);
      const condition = db.captured.where.map((item) => `(${item.sql})`).join(' AND ');
      assert(condition, 'Missing folder path predicates');
      sqlCheck(`direct child: ${assetPath}`, assetPath, condition, true);
      sqlCheck(`nested child excluded: ${assetPath}`, directoryPath + `child${flavor.sep}photo.jpg`, condition, false);
      if (assetPath.includes('100%_real')) {
        sqlCheck('LIKE wildcard escaping', assetPath.replace('100%_real', '100XXreal'), condition, false);
      }
      if (flavor === path.win32) {
        for (const requestedPath of new Set([displayPath + '/', directoryPath])) {
          db = database(); view.db = db.query;
          await view.getAssetsByOriginalPath('user', requestedPath);
          assert.equal(db.captured.where[0].right, `%${escapedDirectory}%`);
          const alternate = db.captured.where.map((item) => `(${item.sql})`).join(' AND ');
          sqlCheck(`alternate folder spelling: ${requestedPath}`, assetPath, alternate, true);
        }
      }
    }
  }

  for (const flavor of [path.win32, path.posix]) {
    const asset = probe('repositories/asset.repository.ts', ['detectOfflineExternalAssets'], flavor, {
      globToPostgresRegex: (glob) => { assert.equal(glob, '**/excluded/**'); return picomatch ? picomatch.makeRe(glob).source : '(^|.*/)excluded(/.*|$)'; },
    });
    const roots = flavor === path.win32
      ? ['D:\\Photos', 'D:/Photos', 'D:\\100%_real', '\\\\host\\share\\Photos']
      : ['/photos', '/100%_real', '/photos\\literal'];
    for (const root of roots) {
      const db = database(); asset.db = db.query;
      await asset.detectOfflineExternalAssets('library', [root], ['**/excluded/**']);
      const condition = db.captured.where[0].sql;
      const originalPath = flavor.join(root, 'photo.jpg');
      sqlCheck(`external asset stays online: ${root}`, originalPath, condition, false);
      sqlCheck(`external exclusion matches: ${root}`, flavor.join(root, 'excluded', 'photo.jpg'), condition, true);
      if (root.includes('100%_real')) {
        sqlCheck('external root LIKE wildcard escaping', originalPath.replace('100%_real', '100XXreal'), condition, true);
      }
    }
    const discovered = flavor === path.win32 ? ['D:/Photos/a.jpg', '//host/share/Photos/b.jpg'] : ['/photos/a.jpg', '/photos\\literal/b.jpg'];
    const storage = probe('repositories/storage.repository.ts', ['crawl', 'walk'], flavor, {
      glob: async () => discovered,
      globStream: async function* () { yield* discovered; },
    });
    storage.asGlob = (value) => value;
    const options = { pathsToCrawl: ['unused'], exclusionPatterns: [], includeHidden: false, take: 1 };
    const expected = discovered.map(flavor.normalize);
    assert.deepEqual(await storage.crawl(options), expected);
    const batches = [];
    for await (const batch of storage.walk(options)) batches.push(...batch);
    assert.deepEqual(batches, expected);
    // The exact strings sent to filterNewExternalAssetPaths must equal the stored
    // processEntity originalPath and path-derived checksum input on the next scan.
    const library = probe('services/library.service.ts', ['processEntity'], flavor, {
      ChecksumAlgorithm: { sha1Path: 'sha1Path' }, AssetType: { Image: 'image', Video: 'video' },
      mimeTypes: { isVideo: () => false }, parse: flavor.parse,
    });
    library.storageRepository = { stat: async () => ({ mtime: new Date(0) }) };
    library.cryptoRepository = { hashSha1: (value) => value };
    for (let index = 0; index < discovered.length; index++) {
      const imported = await library.processEntity(discovered[index], 'user', 'library');
      assert.equal(batches[index], imported.originalPath, 'Rescan must use the already stored path');
      assert.equal(imported.checksum, `path:${batches[index]}`);
      checks++;
    }
    const serviceSource = fs.readFileSync(path.join(sourceRoot, 'server/src/services/library.service.ts'), 'utf8');
    const membership = serviceSource.match(/const isInImportPath = ([^;]+);/);
    assert(membership, 'Missing offline asset reactivation guard');
    const belongs = new Function('job', 'asset', 'path', `return ${membership[1]}`);
    assert.equal(belongs({ importPaths: [roots[1]] }, { originalPath: flavor.join(roots[1], 'photo.jpg') }, flavor), true);
    const excluded = serviceSource.match(/const isExcluded = ([\s\S]*?);/);
    assert(excluded, 'Missing offline asset exclusion guard');
    const matching = picomatch || { isMatch: (value, pattern, options) => {
      assert.equal(options.windows, flavor === path.win32);
      return /(^|[\\/])excluded([\\/]|$)/.test(value);
    } };
    const isExcluded = new Function('job', 'asset', 'picomatch', 'process', `return ${excluded[1]}`);
    assert.equal(isExcluded({ exclusionPatterns: ['**/excluded/**'] }, { originalPath: flavor.join(roots[0], 'excluded', 'photo.jpg') }, matching, { platform: flavor === path.win32 ? 'win32' : 'linux' }), true);
    const watcherOptions = serviceSource.match(/const matcher = picomatch\(`[\s\S]*?`, (\{[\s\S]*?\n    \})\);/);
    assert(watcherOptions, 'Missing watcher glob options');
    const optionsForWatch = new Function('library', 'process', `return (${watcherOptions[1]})`)({ exclusionPatterns: ['**/excluded/**'] }, { platform: flavor === path.win32 ? 'win32' : 'linux' });
    assert.equal(optionsForWatch.windows, flavor === path.win32);
    if (picomatch) {
      const matcher = picomatch('**/*.jpg', optionsForWatch);
      assert.equal(matcher(flavor.join(roots[0], 'photo.jpg')), true);
      assert.equal(matcher(flavor.join(roots[0], 'excluded', 'photo.jpg')), false);
    }
    checks += 2;
  }
  const sql = `\\set ON_ERROR_STOP on\nSET standard_conforming_strings = on;\nBEGIN;\nDO $portability$\nBEGIN\n${sqlChecks.join('\n')}\nEND\n$portability$;\nROLLBACK;\n`;
  const outputIndex = process.argv.indexOf('--sql-output');
  if (outputIndex >= 0) fs.writeFileSync(process.argv[outputIndex + 1], sql);
  const psqlIndex = process.argv.indexOf('--psql');
  if (psqlIndex >= 0) {
    const result = spawnSync(process.argv[psqlIndex + 1], ['-X', '--no-password', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8' });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    console.log(`PostgreSQL portability assertions passed: ${sqlChecks.length}`);
  }
  console.log(`Patched source-method checks passed; ${checks} cases covered (${sqlChecks.length} SQL assertions${psqlIndex < 0 ? ' generated, not executed' : ' executed'})`);
})().catch((error) => { console.error(error); process.exitCode = 1; });
