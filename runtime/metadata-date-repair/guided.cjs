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
  done: ['Repair completed.', '修復が完了しました。'],
  empty: ['No eligible dates to repair. Excluded items were left unchanged.', '安全に修復できる対象はありません。除外された項目は変更していません。'],
  limit: ['The 100,000-candidate safety limit was reached. The scan is incomplete; no dates were changed.', '候補100,000件の安全上限に達しました。確認が完了していないため、日付は変更していません。'],
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
    core.insist(['--release-root','--output-root','--language'].includes(key) && !(key in options) && argv[i + 1] && !argv[i + 1].startsWith('--'), 'invalid-guided-arguments');
    options[key] = argv[i + 1];
  }
  core.insist(options['--release-root'] && path.isAbsolute(options['--release-root']) && options['--output-root'] && path.isAbsolute(options['--output-root']), 'absolute-guided-paths-required');
  core.insist(['en','ja'].includes(options['--language']), 'invalid-guided-language');
  return { releaseRoot: options['--release-root'], outputRoot: options['--output-root'], language: options['--language'] };
}
async function runGuided({ releaseRoot, outputRoot, language = 'en' }, io, dependencies = {}) {
  const createAdapter = dependencies.createAdapter || require('./runtime.cjs').createAdapter;
  const run = dependencies.run || require('./cli.cjs').run;
  let directory, applying = false;
  const say = (key, value) => io.write(text(language, key) + (value === undefined ? '' : ': ' + value));
  try {
    say('title');
    let users, timezone;
    const directoryAdapter = await createAdapter({ releaseRoot, usersOnly: true });
    try { users = await directoryAdapter.listUsers(); timezone = directoryAdapter.identity.timezone; }
    finally { await directoryAdapter.close(); }
    if (!users.length) { say('noUsers'); return { status: 'empty-users', applied: 0 }; }
    users.forEach((user, i) => io.write(`${i + 1}. ${label(user.name)} (${label(user.email)})`));
    const selected = await choose(io, text(language, 'users'), users.length, language);
    if (selected === null) { say('cancelled'); return { status: 'cancelled', applied: 0 }; }
    const user = users[selected];
    say('user', `${label(user.name)} (${label(user.email)})`); say('timezone', label(timezone));
    await fs.mkdir(outputRoot, { recursive: true, mode: 0o700 });
    const output = await fs.realpath(outputRoot);
    directory = await fs.mkdtemp(path.join(output, 'repair-'));
    const indexFile = path.join(directory, 'plan.json');
    say('saved', directory); say('scanning');
    const common = ['--release-root', releaseRoot, '--owner-id', user.id, '--expected-timezone', timezone];
    const scanStarted = performance.now();
    const planned = await run(['plan-all', ...common, '--out', indexFile], {
      emit() {}, onEvent: event => { if (event.kind === 'plan-progress') {
        const seconds = (performance.now() - scanStarted) / 1000;
        say('checked', `${event.inspected}; ${text(language, 'proposed')}: ${event.proposed}; ${text(language, 'elapsed')}: ${seconds.toFixed(1)}s; ${seconds > 0 ? (event.inspected / seconds).toFixed(1) : '0.0'} ${text(language, 'rate')}`);
      } },
    });
    const index = JSON.parse(await fs.readFile(indexFile, 'utf8'));
    core.insist(index.format === core.INDEX_FORMAT && index.scope?.ownerId === user.id && index.identity?.timezone === timezone && core.hash(index) === planned.indexDigest, 'guided-plan-identity-mismatch');
    core.insist(Number.isInteger(index.inspected) && Number.isInteger(index.proposed) && index.proposed >= 0 && index.inspected >= index.proposed, 'guided-plan-count-mismatch');
    say('checked', index.inspected); say('proposed', index.proposed); say('excluded', index.inspected - index.proposed);
    if (!index.exhausted) { say('limit'); return { status: 'incomplete', applied: 0, directory }; }
    if (!index.proposed) { say('empty'); return { status: 'empty', applied: 0, directory }; }
    say('changes'); say('history');
    const approvedDigest = core.hash(index);
    if (await choose(io, text(language, 'confirm'), 1, language) === null) { say('cancelled'); return { status: 'cancelled', applied: 0, directory }; }
    applying = true; say('applying');
    const result = await run(['apply-all', ...common, '--index', indexFile, '--approved-index-sha256', approvedDigest, '--journal-dir', directory, '--acknowledge-history-ambiguity'], {
      emit() {}, onEvent: event => { if (event.kind === 'apply-progress') say('repaired', `${event.completed} / ${index.proposed}`); },
    });
    core.insist(result.completed === index.proposed, 'guided-apply-count-mismatch');
    say('done'); say('repaired', result.completed); say('saved', directory);
    return { status: 'complete', applied: result.completed, directory };
  } catch (error) {
    say('failed', error instanceof core.Stop ? error.code : 'operation-failed');
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
