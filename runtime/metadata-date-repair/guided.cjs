'use strict';
// The interactive entry point delegates all planning and writes to the same CLI.
const fs = require('node:fs/promises');
const path = require('node:path');
const readline = require('node:readline');
const core = require('./core.cjs');

const messages = {
  title: ['Immich date repair', 'Immich 日付修復'],
  users: ['Choose the Immich user to repair (0: cancel):', '修復するImmichユーザーを選んでください（0: キャンセル）:'],
  invalid: ['Enter one of the displayed numbers.', '表示されている番号を入力してください。'],
  cancelled: ['Cancelled. No dates were changed.', 'キャンセルしました。日付は変更していません。'],
  noUsers: ['No active Immich users were found.', '有効なImmichユーザーが見つかりませんでした。'],
  scanning: ['Checking suspicious dates. Keep this window open.', '修復候補の日付を確認しています。この画面を閉じないでください。'],
  checked: ['Candidates checked', '確認した候補'],
  elapsed: ['Elapsed', '経過'],
  rate: ['candidates/s', '候補/秒'],
  proposed: ['Dates to repair', '修復対象'],
  excluded: ['Excluded by safety checks', '安全性の確認で除外'],
  user: ['Selected user', '選択したユーザー'],
  timezone: ['Installed server timezone', 'インストール済みサーバーのタイムゾーン'],
  saved: ['Private plan and recovery journals', '非公開の修復計画・復旧記録'],
  history: [core.HISTORY_WARNING, '過去に削除されたXMPや、以前のデータベース上の手動日付編集は、この不具合と区別できない場合があります。過去の手動編集がなかったことまでは証明できません。'],
  changes: ['Only local date/time and timezone are repaired. Original capture instants and image files are preserved.', 'ローカル日時とタイムゾーンのみを修復します。元の撮影時刻と画像ファイルは保持します。'],
  confirm: ['Accept this uncertainty and apply the displayed plan? 1: repair / 0: cancel', 'この不確実性を了承して、表示した計画で修復しますか？ 1: 修復する / 0: キャンセル'],
  applying: ['Repairing the approved dates. Keep this window open.', '確認した日付を修復しています。この画面を閉じないでください。'],
  repaired: ['Repaired', '修復済み'],
  resumed: ['Reusing saved candidates', '保存済み候補を再利用'],
  keepFolders: ['Keep both the previous and new repair folders until repair/recovery is finished.', '修復・復旧が完了するまで、以前の修復フォルダーと新しい修復フォルダーの両方を保管してください。'],
  errorLog: ['Error log', 'エラーログ'],
  logFailed: ['Could not save the error log', 'エラーログを保存できませんでした'],
  done: ['Repair completed.', '修復が完了しました。'],
  empty: ['No eligible dates to repair. Excluded items were left unchanged.', '安全に修復できる対象はありません。除外された項目は変更していません。'],
  incomplete: ['The scan is incomplete; no dates were changed.', '確認が完了していないため、日付は変更していません。'],
  failed: ['Stopped before completion. Error code', '完了前に停止しました。エラーコード'],
  uncertain: ['Earlier changes may already be committed. Keep the plan and journals; reconcile them before retrying.', '停止前の変更が確定している場合があります。計画・復旧記録を保管し、再実行の前に適用状態を確認してください。'],
};
function text(language, key) { return messages[key][language === 'ja' ? 1 : 0]; }
function label(value) { return String(value).replace(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, ' ').slice(0, 160); }
function terminal(input = process.stdin, output = process.stdout) {
  const reader = readline.createInterface({ input, output, terminal: !!(input.isTTY && output.isTTY), crlfDelay: Infinity });
  const lines = reader[Symbol.asyncIterator]();
  return {
    write: line => output.write(line + '\n'),
    async ask(prompt) { output.write(prompt + '\n> '); const next = await lines.next(); return next.done ? null : next.value.trim(); },
    close: () => reader.close(),
  };
}
async function choose(io, prompt, count, language) {
  for (;;) {
    const answer = await io.ask(prompt);
    if (answer === null || answer === '' || answer === '0') return null;
    if (/^[1-9][0-9]*$/.test(answer) && Number(answer) <= count) return Number(answer) - 1;
    io.write(text(language, 'invalid'));
  }
}
function parse(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    core.insist(['--release-root','--output-root','--language','--resume-directory'].includes(key) && !(key in options) && argv[i + 1] && !argv[i + 1].startsWith('--'), 'invalid-guided-arguments');
    options[key] = argv[i + 1];
  }
  core.insist(options['--release-root'] && path.isAbsolute(options['--release-root']) && options['--output-root'] && path.isAbsolute(options['--output-root']), 'absolute-guided-paths-required');
  core.insist(['en','ja'].includes(options['--language']), 'invalid-guided-language');
  if (options['--resume-directory']) core.insist(path.isAbsolute(options['--resume-directory']), 'absolute-resume-path-required');
  return { releaseRoot: options['--release-root'], outputRoot: options['--output-root'], language: options['--language'], ...(options['--resume-directory'] ? { resumeDirectory: options['--resume-directory'] } : {}) };
}
async function runGuided({ releaseRoot, outputRoot, language = 'en', resumeDirectory }, io, dependencies = {}) {
  const createAdapter = dependencies.createAdapter || require('./runtime.cjs').createAdapter;
  const run = dependencies.run || require('./cli.cjs').run;
  const persistFailure = dependencies.persistFailure || require('./cli.cjs').persistFailure;
  let directory, applying = false, lastProgress = { inspected: 0, proposed: 0 }, resumedCount = 0;
  const recorded = new Set();
  const say = (key, value) => io.write(text(language, key) + (value === undefined ? '' : ': ' + value));
  const ensureDirectory = async () => {
    if (!directory) { await fs.mkdir(outputRoot, { recursive: true, mode: 0o700 }); directory = await fs.mkdtemp(path.join(await fs.realpath(outputRoot), 'repair-')); }
  };
  const recordFailure = async (error, { cleanup = false } = {}) => {
    if (recorded.has(error)) return; recorded.add(error);
    const details = { operation: applying ? 'apply-all' : 'plan-all', ...core.failureDetails(error), completedPage: lastProgress, cleanup };
    say('failed', `${details.phase} / ${details.code} / ${details.errorClass}${details.assetId ? ' / ' + details.assetId : ''}`);
    try { await ensureDirectory(); say('errorLog', await persistFailure(directory, details, { cleanup })); }
    catch (logError) { say('logFailed', core.failureDetails(logError).code); }
  };
  try {
    say('title');
    let users, timezone;
    const directoryAdapter = await core.atStage('user-runtime', () => createAdapter({ releaseRoot, usersOnly: true }));
    let userError;
    try { users = await core.atStage('user-list', () => directoryAdapter.listUsers()); timezone = directoryAdapter.identity.timezone; }
    catch (error) { userError = error; await recordFailure(error); throw error; }
    finally { try { await directoryAdapter.close(); } catch (error) { await recordFailure(error, { cleanup: !!userError }); if (!userError) throw error; } }
    if (!users.length) { say('noUsers'); return { status: 'empty-users', applied: 0 }; }
    users.forEach((user, i) => io.write(`${i + 1}. ${label(user.name)} (${label(user.email)})`));
    const selected = await choose(io, text(language, 'users'), users.length, language);
    if (selected === null) { say('cancelled'); return { status: 'cancelled', applied: 0 }; }
    const user = users[selected];
    say('user', `${label(user.name)} (${label(user.email)})`); say('timezone', label(timezone));
    await ensureDirectory();
    const indexFile = path.join(directory, 'plan.json');
    say('saved', directory); say('scanning');
    const common = ['--release-root', releaseRoot, '--owner-id', user.id, '--expected-timezone', timezone];
    const scanStarted = performance.now();
    const planned = await run(['plan-all', ...common, '--out', indexFile, ...(resumeDirectory ? ['--resume-directory', resumeDirectory] : [])], {
      emit() {}, onFailure: recordFailure, onEvent: event => {
        if (event.kind === 'resumed') { resumedCount = event.inspected; lastProgress = { inspected: event.inspected, proposed: event.proposed }; say('resumed', event.inspected); say('keepFolders'); }
        if (event.kind === 'plan-progress') {
        lastProgress = { inspected: event.inspected, proposed: event.proposed };
        const seconds = (performance.now() - scanStarted) / 1000;
        say('checked', `${event.inspected}; ${text(language, 'proposed')}: ${event.proposed}; ${text(language, 'elapsed')}: ${seconds.toFixed(1)}s; ${seconds > 0 ? ((event.inspected - resumedCount) / seconds).toFixed(1) : '0.0'} ${text(language, 'rate')}`);
      } },
    });
    const index = JSON.parse(await fs.readFile(indexFile, 'utf8'));
    core.insist(index.format === core.INDEX_FORMAT && index.scope?.ownerId === user.id && index.identity?.timezone === timezone && core.hash(index) === planned.indexDigest, 'guided-plan-identity-mismatch');
    core.insist(Number.isInteger(index.inspected) && Number.isInteger(index.proposed) && index.proposed >= 0 && index.inspected >= index.proposed, 'guided-plan-count-mismatch');
    say('checked', index.inspected); say('proposed', index.proposed); say('excluded', index.inspected - index.proposed);
    if (!index.exhausted) { say('incomplete'); return { status: 'incomplete', applied: 0, directory }; }
    if (!index.proposed) { say('empty'); return { status: 'empty', applied: 0, directory }; }
    say('changes'); say('history');
    const approvedDigest = core.hash(index);
    if (await choose(io, text(language, 'confirm'), 1, language) === null) { say('cancelled'); return { status: 'cancelled', applied: 0, directory }; }
    applying = true; say('applying');
    const result = await run(['apply-all', ...common, '--index', indexFile, '--approved-index-sha256', approvedDigest, '--journal-dir', directory, '--acknowledge-history-ambiguity'], {
      emit() {}, onFailure: recordFailure, onEvent: event => { if (event.kind === 'apply-progress') say('repaired', `${event.completed} / ${index.proposed}`); },
    });
    core.insist(result.completed === index.proposed, 'guided-apply-count-mismatch');
    say('done'); say('repaired', result.completed); say('saved', directory);
    return { status: 'complete', applied: result.completed, directory };
  } catch (error) {
    await recordFailure(error);
    if (applying) say('uncertain');
    if (directory) say('saved', directory);
    throw error;
  }
}
if (require.main === module) {
  let io;
  Promise.resolve().then(() => {
    const options = parse(process.argv.slice(2)); io = terminal(); return runGuided(options, io);
  }).then(result => { if (result.status === 'incomplete') process.exitCode = 2; }).catch(() => { process.exitCode = 2; }).finally(() => io?.close());
}
module.exports = { runGuided, terminal, choose, parse, label };
