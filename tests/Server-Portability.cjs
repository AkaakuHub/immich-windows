// Execute the patched upstream method bodies, then emit/run PostgreSQL assertions
// for their SQL expressions and migrations using temporary fixture tables.
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
const migrationChecks = [];
let checks = 0;
const literal = (value) => value === null ? 'NULL' : `'${String(value).replaceAll("'", "''")}'`;
const expression = (sql) => ({ sql, as() { return this; } });
const sql = (parts, ...values) => expression(parts.reduce((result, part, index) => result + part + (index < values.length ? values[index]?.sql ?? literal(values[index]) : ''), ''));
sql.ref = columnName => column(columnName);
sql.lit = value => expression(literal(value));
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
  const captured = { where: [], select: null, orderBy: null, updates: [] };
  const query = {
    selectFrom() { return this; }, updateTable(table) { captured.table = table; return this; },
    transaction() { return { execute: callback => callback(this) }; },
    select(value) { if (typeof value === 'function') captured.select = value(eb); return this; },
    selectAll() { return this; }, distinct() { return this; }, set(value) { captured.updates.push({ table: captured.table, values: typeof value === 'function' ? value(eb) : value }); return this; }, $call() { return this; },
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
  for (const flavor of [path.win32, path.posix]) {
    const repository = probe('repositories/database.repository.ts', ['migrateFilePaths'], flavor, { sql });
    const db = database(); repository.db = db.query;
    const source = flavor === path.win32 ? 'D:\\old\\' : '/old/';
    const target = flavor === path.win32 ? 'E:\\new\\' : '/new/';
    await repository.migrateFilePaths(source, target);
    assert.equal(db.captured.updates.length, 4);
    for (const update of db.captured.updates) {
      const [field, value] = Object.entries(update.values)[0];
      const original = flavor === path.win32 ? 'D:\\old/thumbs/a.webp' : '/old/thumbs/a.webp';
      const expected = flavor === path.win32 ? 'E:\\new\\thumbs\\a.webp' : '/new/thumbs/a.webp';
      sqlChecks.push(`IF (SELECT ${value.sql} FROM (VALUES (${literal(original)})) AS fixture(${column(field).sql})) IS DISTINCT FROM ${literal(expected)} THEN RAISE EXCEPTION '%', ${literal(`media migration: ${flavor.sep} ${update.table}`)}; END IF;`);
      checks++;
    }
  }
  const migrationFile = 'server/src/schema/migrations/1787148183731-NormalizeWindowsMediaPaths.ts';
  const migrationSource = fs.readFileSync(path.join(sourceRoot, migrationFile), 'utf8');
  const migrationCode = source => stripTypeScriptTypes(source.replace(/^import .*;\r?\n/gm, '').replaceAll('export ', ''));
  const migrationQueries = [];
  const migrationSql = (parts, ...values) => ({ async execute() { migrationQueries.push(sql(parts, ...values).sql); } });
  const migrate = (platform, source = migrationSource) => new Function('sql', 'process', `${migrationCode(source)}\nreturn up;`)(migrationSql, { platform })({});
  await migrate('linux');
  assert.equal(migrationQueries.length, 0, 'POSIX databases must not be rewritten');
  await migrate('win32');
  assert.equal(migrationQueries.length, 7);
  const expectedQueries = [...migrationQueries];
  migrationQueries.length = 0;
  await migrate('win32', migrationSource.replace(/\r?\n/g, '\r\n'));
  assert.deepEqual(migrationQueries, expectedQueries, 'Windows checkout line endings must execute the same migration');
  const order = fs.readFileSync(path.join(sourceRoot, 'server/src/schema/migrations/ORDER'), 'utf8');
  assert(order.includes(path.basename(migrationFile, '.ts')), 'Repair migration must be registered');
  migrationChecks.push(`SET LOCAL search_path = pg_temp;
CREATE TEMP TABLE asset ("originalPath" text);
CREATE TEMP TABLE asset_file (path text);
CREATE TEMP TABLE person ("thumbnailPath" text);
CREATE TEMP TABLE "user" ("profileImagePath" text);
CREATE TEMP TABLE integrity_report (id integer PRIMARY KEY, type text, path text, "assetId" integer, "fileAssetId" integer, "createdAt" timestamptz DEFAULT now(), UNIQUE(type, path));
INSERT INTO asset VALUES ('D:/upload/library/photo.jpg');
INSERT INTO asset_file VALUES (${literal('D:\\upload/thumbs/a.webp')});
INSERT INTO person VALUES ('//host/share/thumbs/person.jpg');
INSERT INTO "user" VALUES ('D:/upload/profile/avatar.jpg');
INSERT INTO integrity_report(id,type,path,"assetId","fileAssetId") VALUES
(1,'untracked_file','D:/upload/library/photo.jpg',NULL,NULL),
(2,'untracked_file',${literal('D:\\upload\\library\\photo.jpg')},NULL,NULL),
(3,'untracked_file',${literal('D:\\upload\\thumbs\\a.webp')},NULL,NULL),
(4,'untracked_file',${literal('\\\\host\\share\\thumbs\\person.jpg')},NULL,NULL),
(5,'untracked_file','D:/upload/orphan.jpg',NULL,NULL),
(6,'untracked_file',${literal('D:\\upload\\orphan.jpg')},NULL,NULL),
(7,'missing_file','D:/upload/missing.jpg',42,NULL),
(8,'checksum_mismatch','D:/upload/library/photo.jpg',42,NULL),
(9,'missing_file',${literal('D:\\upload\\missing.jpg')},NULL,NULL),
(10,'untracked_file','D:/upload/other.jpg',NULL,NULL);
${migrationQueries.join(';\n')};
DO $repair$
BEGIN
IF (SELECT count(*) FROM integrity_report WHERE type='untracked_file') <> 2 THEN RAISE EXCEPTION 'False reports removed; both unresolved files must remain'; END IF;
IF NOT EXISTS (SELECT FROM integrity_report WHERE id=7 AND "assetId"=42 AND path=${literal('D:\\upload\\missing.jpg')}) THEN RAISE EXCEPTION 'Missing report and its asset link must remain'; END IF;
IF NOT EXISTS (SELECT FROM integrity_report WHERE id=8 AND "assetId"=42) THEN RAISE EXCEPTION 'Checksum mismatch must remain'; END IF;
IF (SELECT count(*) FROM asset) <> 1 OR (SELECT count(*) FROM asset_file) <> 1 OR (SELECT count(*) FROM person) <> 1 OR (SELECT count(*) FROM "user") <> 1 THEN RAISE EXCEPTION 'Media references must not be removed'; END IF;
IF (SELECT "originalPath" FROM asset) <> ${literal('D:\\upload\\library\\photo.jpg')} OR (SELECT path FROM asset_file) <> ${literal('D:\\upload\\thumbs\\a.webp')} OR (SELECT "thumbnailPath" FROM person) <> ${literal('\\\\host\\share\\thumbs\\person.jpg')} OR (SELECT "profileImagePath" FROM "user") <> ${literal('D:\\upload\\profile\\avatar.jpg')} THEN RAISE EXCEPTION 'All media path columns must use native separators'; END IF;
END $repair$;
CREATE TEMP TABLE first_repair AS SELECT * FROM integrity_report;
${migrationQueries.join(';\n')};
DO $repeat$
BEGIN
IF EXISTS ((SELECT * FROM integrity_report EXCEPT SELECT * FROM first_repair) UNION ALL (SELECT * FROM first_repair EXCEPT SELECT * FROM integrity_report)) THEN RAISE EXCEPTION 'Repeated repair must be idempotent'; END IF;
END $repeat$;`);
  checks += 8;
  const queryScript = `\\set ON_ERROR_STOP on\nSET standard_conforming_strings = on;\nBEGIN;\nDO $portability$\nBEGIN\n${sqlChecks.join('\n')}\nEND\n$portability$;\n${migrationChecks.join('\n')}\nROLLBACK;\n`;
  const outputIndex = process.argv.indexOf('--sql-output');
  if (outputIndex >= 0) fs.writeFileSync(process.argv[outputIndex + 1], queryScript);
  const psqlIndex = process.argv.indexOf('--psql');
  if (psqlIndex >= 0) {
    const result = spawnSync(process.argv[psqlIndex + 1], ['-X', '--no-password', '-v', 'ON_ERROR_STOP=1'], { input: queryScript, encoding: 'utf8' });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    console.log(`PostgreSQL portability assertions passed: ${sqlChecks.length}`);
  }
  console.log(`Patched source-method checks passed; ${checks} cases covered (${sqlChecks.length} SQL assertions${psqlIndex < 0 ? ' generated, not executed' : ' executed'})`);
})().catch((error) => { console.error(error); process.exitCode = 1; });
