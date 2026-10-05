import difflib
import hashlib
import json
import sys
import unittest
import urllib.error
from unittest.mock import Mock, patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import check_upstream as check

MAIN, OLD, NEW, HEAD, TREE = 'a' * 40, 'b' * 40, 'c' * 40, 'd' * 40, 'e' * 40
BRANCH = 'automation/upstream-v3.2.4'


def make_pr(head=HEAD, base=MAIN, marker_head=None, marker_base=None):
    return {'number': 12, 'state': 'open', 'draft': True, 'merge_commit_sha': 'f' * 40, 'mergeable': True,
            'body': f'{check.MARKER}\n<!-- immich-windows:automatic-head {marker_head or head} base {marker_base or base} -->',
            'user': {'login': 'github-actions[bot]'},
            'base': {'ref': 'main', 'sha': base, 'repo': {'full_name': 'owner/repo'}},
            'head': {'ref': BRANCH, 'sha': head, 'repo': {'full_name': 'owner/repo'}}}


class FakeAPI:
    repo = 'owner/repo'

    def __init__(self):
        self.pin = {'version': 'v3.2.2', 'windowsRevision': 8, 'commit': OLD}
        self.latest = {'tag_name': 'v3.2.4', 'draft': False, 'prerelease': False}
        self.pr = None
        self.branch = None
        self.runs = []
        self.writes = []
        self.reads = []

    def get(self, path, repo=None):
        self.reads.append((path, repo))
        if path == 'git/ref/heads/main':
            return {'object': {'sha': MAIN}}
        if path == 'releases/latest':
            return self.latest
        if path == 'actions/workflows/build-windows.yml/runs?event=workflow_dispatch&per_page=100':
            return {'workflow_runs': self.runs}
        if path == 'git/ref/tags/v3.2.4':
            return {'object': {'type': 'commit', 'sha': NEW}}
        if path == 'pulls/12':
            return self.pr
        if path == 'git/commits/' + 'f' * 40:
            return {'sha': 'f' * 40, 'parents': [{'sha': MAIN}, {'sha': HEAD}]}
        if path == 'git/commits/' + MAIN:
            return {'sha': MAIN, 'tree': {'sha': TREE}}
        if path == 'git/commits/' + HEAD:
            return {'sha': HEAD, 'tree': {'sha': TREE}, 'parents': [{'sha': MAIN}]}
        if path == 'git/ref/heads/' + BRANCH:
            if self.branch:
                return {'object': {'sha': self.branch}}
            raise urllib.error.HTTPError('', 404, '', {}, None)
        raise AssertionError(f'Unexpected GET: {path} ({repo})')

    def file(self, path, ref, repo=None):
        if path == 'upstream.json':
            return json.dumps(self.pin if ref == MAIN else {'version': 'v3.2.4', 'commit': NEW, 'windowsRevision': 0})
        if path == 'dependencies/versions.json':
            return '{}'
        raise AssertionError(f'Unexpected file: {path}')

    def pages(self, path, key=None):
        if path.startswith('pulls?'):
            return iter([self.pr] if self.pr else [])
        if path == 'actions/workflows/build-windows.yml/runs?event=workflow_dispatch':
            return iter(self.runs)
        raise AssertionError(f'Unexpected pages: {path}')

    def write(self, method, path, data):
        self.writes.append((method, path, data))
        if path == 'git/blobs':
            return {'sha': TREE}
        if path == 'git/trees':
            return {'sha': TREE}
        if path == 'git/commits':
            return {'sha': HEAD}
        if path == 'git/refs':
            self.branch = data['sha']
            return {}
        if path == 'git/refs/heads/' + BRANCH:
            self.branch = data['sha']
            if self.pr:
                self.pr['head']['sha'] = data['sha']
                self.pr['base']['sha'] = MAIN
            return {}
        if path == 'pulls':
            self.pr = make_pr()
            self.pr['body'] = data['body']
            return self.pr
        if path == 'pulls/12':
            self.pr['body'] = data['body']
            return self.pr
        if path.endswith('/dispatches'):
            return None
        raise AssertionError(f'Unexpected write: {method} {path}')


class WatcherTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.prepare = Mock(return_value={'upstream.json': '{}', 'dependencies/versions.json': '{}'})
        self.patch_stack = patch.object(check, 'prepare_patches', return_value={})
        self.preflight = self.patch_stack.start()
        self.addCleanup(self.patch_stack.stop)

    def run_check(self):
        return check.run(self.api, self.prepare)

    def test_same_upstream_never_resets_revision_or_prepares_or_builds(self):
        self.api.latest['tag_name'] = 'v3.2.2'
        self.assertEqual(self.run_check(), 'unchanged')
        self.assertEqual(self.api.writes, [])
        self.prepare.assert_not_called()
        self.preflight.assert_not_called()
        self.assertEqual(len(self.api.reads), 2)

    def test_unchanged_exact_main_can_recover_only_publication(self):
        self.api.latest['tag_name'] = self.api.pin['version']
        recover = Mock(return_value=True)
        self.assertEqual(check.run(self.api, self.prepare, recover), 'publication-recovery')
        recover.assert_called_once_with(MAIN, self.api.pin)
        self.prepare.assert_not_called()
        self.preflight.assert_not_called()
        self.assertEqual(self.api.writes, [])

    def test_published_unchanged_version_remains_noop(self):
        self.api.latest['tag_name'] = self.api.pin['version']
        recover = Mock(return_value=False)
        self.assertEqual(check.run(self.api, self.prepare, recover), 'unchanged')
        recover.assert_called_once()
        self.prepare.assert_not_called()
        self.assertEqual(self.api.writes, [])

    def test_inconsistent_publication_evidence_never_falls_back_to_build(self):
        self.api.latest['tag_name'] = self.api.pin['version']
        recover = Mock(side_effect=ValueError('Existing draft asset differs from qualification'))
        with self.assertRaisesRegex(ValueError, 'asset differs'):
            check.run(self.api, self.prepare, recover)
        self.prepare.assert_not_called()
        self.preflight.assert_not_called()
        self.assertEqual(self.api.writes, [])

    def test_newer_upstream_does_not_invoke_publication_only_recovery(self):
        recover = Mock()
        self.assertEqual(check.run(self.api, self.prepare, recover), 'dispatched')
        recover.assert_not_called()

    def test_active_owned_qualification_defers_newest_without_build_or_pr(self):
        self.api.runs = [{'id': 90, 'event': 'workflow_dispatch', 'head_repository': {'full_name': self.api.repo},
            'actor': {'login': 'github-actions[bot]'}, 'status': 'in_progress', 'conclusion': None,
            'display_title': f'Qualify upstream PR #11 head={OLD} base={MAIN}'}]
        self.assertEqual(self.run_check(), 'active-qualification')
        self.assertEqual(self.api.writes, [])
        self.prepare.assert_not_called()
        self.preflight.assert_not_called()
        self.assertEqual(sum('per_page=100' in entry[0] for entry in self.api.reads), 1)

    def test_terminal_failed_qualification_does_not_block_newer_release(self):
        self.api.runs = [{'id': 90, 'event': 'workflow_dispatch', 'head_repository': {'full_name': self.api.repo},
            'actor': {'login': 'github-actions[bot]'}, 'status': 'completed', 'conclusion': 'failure',
            'display_title': f'Qualify upstream PR #11 head={OLD} base={MAIN}'}]
        self.assertEqual(self.run_check(), 'dispatched')

    def test_older_upstream_never_downgrades(self):
        self.api.latest['tag_name'] = 'v3.2.1'
        self.assertEqual(self.run_check(), 'unchanged')
        self.assertEqual(self.api.writes, [])

    def test_new_version_creates_one_draft_pr_and_dispatches_trusted_main(self):
        self.assertEqual(self.run_check(), 'dispatched')
        self.preflight.assert_called_once_with(self.api, MAIN, OLD, NEW)
        self.prepare.assert_called_once()
        self.assertEqual(self.prepare.call_args.args[-1]['commit'], NEW)
        dispatch = self.api.writes[-1]
        self.assertEqual(dispatch, ('POST', 'actions/workflows/build-windows.yml/dispatches', {
            'ref': 'main', 'inputs': {'component': 'all', 'upstream_pr': '12', 'expected_head': HEAD, 'expected_base': MAIN}}))
        prs = [entry for entry in self.api.writes if entry[1] == 'pulls']
        self.assertEqual(len(prs), 1)
        self.assertTrue(prs[0][2]['draft'])
        self.assertIn(f'automatic-head {HEAD} base {MAIN}', prs[0][2]['body'])

    def test_latest_successful_exact_head_can_recover_completion_without_build(self):
        self.api.pr = make_pr()
        title = f'Qualify upstream PR #12 head={HEAD} base={MAIN}'
        self.api.runs = [{'id': 102, 'event': 'workflow_dispatch', 'head_repository': {'full_name': self.api.repo},
            'status': 'completed', 'conclusion': 'success', 'display_title': title},
            {'id': 101, 'event': 'workflow_dispatch', 'head_repository': {'full_name': self.api.repo},
            'status': 'completed', 'conclusion': 'success', 'display_title': title}]
        recover = Mock(return_value=True)
        self.assertEqual(check.run(self.api, self.prepare, recover_completion=recover), 'completion-recovery')
        recover.assert_called_once_with(102)
        self.prepare.assert_not_called()
        self.assertEqual(self.api.writes, [])

    def test_failed_qualification_never_invokes_completion_recovery(self):
        self.api.pr = make_pr()
        self.api.runs = [{'id': 102, 'event': 'workflow_dispatch', 'head_repository': {'full_name': self.api.repo},
            'status': 'completed', 'conclusion': 'failure',
            'display_title': f'Qualify upstream PR #12 head={HEAD} base={MAIN}'}]
        recover = Mock(return_value=True)
        self.assertEqual(check.run(self.api, self.prepare, recover_completion=recover), 'existing-run')
        recover.assert_not_called()
        self.assertEqual(self.api.writes, [])

    def test_pending_completion_recovery_does_not_dispatch_a_duplicate_build(self):
        self.api.pr = make_pr()
        self.api.runs = [{'id': 102, 'event': 'workflow_dispatch', 'head_repository': {'full_name': self.api.repo},
            'status': 'completed', 'conclusion': 'success',
            'display_title': f'Qualify upstream PR #12 head={HEAD} base={MAIN}'}]
        recover = Mock(return_value=False)
        self.assertEqual(check.run(self.api, self.prepare, recover_completion=recover), 'existing-run')
        recover.assert_called_once_with(102)
        self.assertEqual(self.api.writes, [])

    def test_pending_merge_metadata_defers_without_creating_a_run(self):
        self.api.pr = make_pr()
        self.api.pr['merge_commit_sha'] = None
        self.api.pr['mergeable'] = None
        with patch.object(check.time, 'sleep') as sleep:
            self.assertEqual(self.run_check(), 'awaiting-merge-metadata')
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(self.api.writes, [])
        # No attempt marker prevents the next check from resuming normally.
        self.api.pr['merge_commit_sha'] = 'f' * 40
        self.api.pr['mergeable'] = True
        self.assertEqual(self.run_check(), 'dispatched')

    def test_wrong_merge_parents_never_dispatch(self):
        self.api.pr = make_pr()
        original_get = self.api.get
        def get(path, repo=None):
            value = original_get(path, repo)
            if path == 'git/commits/' + 'f' * 40:
                value['parents'] = [{'sha': OLD}, {'sha': HEAD}]
            return value
        self.api.get = get
        with patch.object(check.time, 'sleep'):
            self.assertEqual(self.run_check(), 'awaiting-merge-metadata')
        self.assertEqual(self.api.writes, [])

    def test_pending_success_and_failed_exact_head_are_not_built_again(self):
        for status, conclusion in [('in_progress', None), ('completed', 'success'), ('completed', 'failure')]:
            with self.subTest(conclusion=conclusion):
                self.api = FakeAPI()
                self.api.pr = make_pr()
                self.api.runs = [{'id': 100, 'event': 'workflow_dispatch', 'head_sha': MAIN,
                    'head_repository': {'full_name': self.api.repo}, 'status': status, 'conclusion': conclusion,
                    'display_title': f'Qualify upstream PR #12 head={HEAD} base={MAIN}'}]
                self.assertEqual(self.run_check(), 'existing-run')
                self.assertEqual(self.api.writes, [])
        self.prepare.assert_not_called()

    def test_other_head_or_base_run_does_not_suppress_qualification(self):
        self.api.pr = make_pr()
        self.api.runs = [{'id': 100, 'event': 'workflow_dispatch', 'head_repository': {'full_name': self.api.repo},
            'status': 'completed', 'conclusion': 'success',
            'display_title': f'Qualify upstream PR #12 head={HEAD} base={OLD}'}]
        self.assertEqual(self.run_check(), 'dispatched')

    def test_closed_pr_stays_closed_and_no_replacement_is_created(self):
        self.api.pr = dict(make_pr(), state='closed')
        self.assertEqual(self.run_check(), 'closed')
        self.assertEqual(self.api.writes, [])

    def test_manually_modified_head_is_not_adopted(self):
        self.api.pr = make_pr(marker_head=OLD)
        with self.assertRaisesRegex(ValueError, 'changed outside'):
            self.run_check()
        self.assertEqual(self.api.writes, [])

    def test_human_created_pr_is_not_adopted(self):
        self.api.pr = make_pr()
        self.api.pr['user']['login'] = 'human'
        with self.assertRaisesRegex(ValueError, 'not created'):
            self.run_check()
        self.assertEqual(self.api.writes, [])

    def test_stale_bot_head_is_regenerated_without_force_push(self):
        self.api.pr = make_pr(base=OLD)
        self.api.branch = HEAD
        self.assertEqual(self.run_check(), 'dispatched')
        commits = [x for x in self.api.writes if x[1] == 'git/commits']
        self.assertEqual(commits[0][2]['parents'], [HEAD, MAIN])
        updates = [x for x in self.api.writes if x[1] == 'git/refs/heads/' + BRANCH]
        self.assertEqual(updates[0][2], {'sha': HEAD, 'force': False})
        self.assertIn(f'base {MAIN}', self.api.pr['body'])

    def test_interrupted_creation_recovers_existing_branch_without_new_commit(self):
        self.api.branch = HEAD
        self.assertEqual(self.run_check(), 'dispatched')
        self.assertFalse(any(x[1] == 'git/commits' for x in self.api.writes))
        self.prepare.assert_called_once()

    def test_unowned_branch_with_unrelated_tree_is_not_adopted(self):
        self.api.branch = HEAD
        original_get = self.api.get
        def get(path, repo=None):
            result = original_get(path, repo)
            if path == 'git/commits/' + HEAD:
                result['tree']['sha'] = 'f' * 40
            return result
        self.api.get = get
        with self.assertRaisesRegex(ValueError, 'refusing to adopt'):
            self.run_check()
        self.assertFalse(any(x[1] in ('pulls', 'actions/workflows/build-windows.yml/dispatches') for x in self.api.writes))

    def test_prerelease_and_malformed_versions_fail_before_any_write(self):
        for version, prerelease in [('v3.3.0-rc1', True), ('v03.3.0', False), ('v3.3.0\n', False)]:
            self.api = FakeAPI()
            self.api.latest.update(tag_name=version, prerelease=prerelease)
            with self.assertRaises(ValueError):
                self.run_check()
            self.assertEqual(self.api.writes, [])

    def test_updater_cannot_modify_workflow_or_escape_paths(self):
        self.prepare.return_value['.github/workflows/build-windows.yml'] = 'unsafe'
        with self.assertRaisesRegex(ValueError, 'Unexpected updater output'):
            self.run_check()
        self.assertFalse(any(x[1] in ('git/trees', 'git/commits', 'git/refs', 'pulls') for x in self.api.writes))


    def test_updater_can_rebase_and_remove_both_patch_stacks(self):
        self.preflight.return_value = {
            'patches/server/fix.patch': 'rebased Windows patch',
            'metadata-patches/server/fix.patch': None,
            'metadata-patches/series': '# Metadata corrections\n',
        }
        self.assertEqual(self.run_check(), 'dispatched')
        entries = next(data['tree'] for _, path, data in self.api.writes if path == 'git/trees')
        paths = {entry['path']: entry for entry in entries}
        self.assertEqual(paths['metadata-patches/server/fix.patch']['sha'], None)
        self.assertIn('metadata-patches/series', paths)
        self.assertIn('patches/server/fix.patch', paths)

    def test_updater_rejects_disallowed_metadata_outputs_before_any_write(self):
        for path in ('metadata-patches/machine-learning/fix.patch', 'metadata-patches/README.md',
                     'metadata-patches/server/../fix.patch', 'metadata-patches/server/.git/fix.patch',
                     'metadata-patches/server/fix.patch:stream', 'metadata-patches/server/a\\b.patch'):
            with self.subTest(path=path):
                self.preflight.return_value = {path: 'unsafe'}
                with self.assertRaises(ValueError):
                    self.run_check()
                self.assertEqual(self.api.writes, [])

    def test_failed_patch_preflight_creates_no_external_state(self):
        self.preflight.side_effect = ValueError('Cannot automatically apply Windows patch example.patch')
        with self.assertRaisesRegex(ValueError, 'Cannot automatically apply'):
            self.run_check()
        self.assertEqual(self.api.writes, [])


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.before = ''.join(f'line {n}\n' for n in range(1, 16))
        self.after = self.before.replace('line 7\n', 'Windows fix\n')
        self.patch = ''.join(difflib.unified_diff(self.before.splitlines(True), self.after.splitlines(True),
                                               fromfile='a/server/example.ts', tofile='b/server/example.ts'))
        self.series = '# Stack\nserver/fix.patch\n'

    def preflight(self, new_source):
        api = Mock()
        def file(path, ref, repo=None):
            if path == 'metadata-patches/series':
                return '# Metadata corrections\n'
            if path == 'patches/series':
                return self.series
            if path == 'patches/server/fix.patch':
                return self.patch
            if path == 'server/example.ts':
                return self.before if ref == OLD else new_source
            raise AssertionError(path)
        api.file.side_effect = file
        return check.prepare_patches(api, MAIN, OLD, NEW)

    def test_unchanged_source_keeps_exact_patch_bytes(self):
        self.assertEqual(self.preflight(self.before), {})

    def test_offset_context_applies_without_rewriting_patch(self):
        self.assertEqual(self.preflight('new heading\n' + self.before), {})

    def test_exact_upstream_fix_removes_patch_and_series_entry(self):
        self.assertEqual(self.preflight(self.after), {'patches/server/fix.patch': None, 'patches/series': '# Stack\n'})

    def test_context_drift_uses_clean_three_way_merge(self):
        changed = self.preflight(self.before.replace('line 4\n', 'upstream improvement\n'))
        self.assertIn('patches/server/fix.patch', changed)
        self.assertIn('+Windows fix', changed['patches/server/fix.patch'])
        self.assertIn('upstream improvement', changed['patches/server/fix.patch'])

    def test_three_way_base_blob_preserves_bytes_with_windows_text_mode(self):
        # This trailing line is outside the patch context. Preserve both UTF-8
        # and existing CRLF bytes, as well as the LF bytes in the original source.
        self.before += 'UTF-8: caf\u00e9 \u65e5\u672c\u8a9e\r\n'
        source_bytes = self.before.encode('utf-8')
        expected_hash = hashlib.sha1(b'blob ' + str(len(source_bytes)).encode('ascii')
                                    + b'\0' + source_bytes).hexdigest()
        run = check.subprocess.run
        blob_hashes, three_way_results = [], []

        def windows_run(arguments, **kwargs):
            # Emulate TextIOWrapper's Windows stdin conversion even on Linux;
            # still run real Git so a wrong blob cannot satisfy --3way.
            text_input = kwargs.get('text') and kwargs.get('input') is not None
            if text_input:
                kwargs['input'] = kwargs['input'].replace('\n', '\r\n').encode('utf-8')
                kwargs['text'] = False
            result = run(arguments, **kwargs)
            if text_input:
                result.stdout = result.stdout.decode('utf-8')
                result.stderr = result.stderr.decode('utf-8')
            if arguments[3:] == ['hash-object', '-w', '--stdin']:
                digest = result.stdout.decode('ascii') if isinstance(result.stdout, bytes) else result.stdout
                blob_hashes.append(digest.strip())
            if arguments[3:5] == ['apply', '--3way']:
                three_way_results.append(result.returncode)
            return result

        with patch.object(check.subprocess, 'run', side_effect=windows_run):
            changed = self.preflight(self.before.replace('line 4\n', 'upstream improvement\n'))
        self.assertEqual(blob_hashes, [expected_hash])
        self.assertEqual(three_way_results, [0])
        self.assertIn('+Windows fix', changed['patches/server/fix.patch'])
        self.assertIn('upstream improvement', changed['patches/server/fix.patch'])

    def test_overlapping_conflict_names_exact_patch_and_stops(self):
        with self.assertRaisesRegex(ValueError, 'Cannot automatically apply patch patches/server/fix.patch'):
            self.preflight(self.before.replace('line 7\n', 'conflicting upstream fix\n'))

    def test_unsafe_target_is_rejected(self):
        self.patch = self.patch.replace('server/example.ts', '../outside.ts')
        with self.assertRaisesRegex(ValueError, 'Unsafe target'):
            self.preflight(self.before)


class CombinedPatchTests(unittest.TestCase):
    def setUp(self):
        self.before = ''.join(f'line {n}\n' for n in range(1, 41))
        self.windows = self.before.replace('line 7\n', 'Windows fix\n')
        self.both = self.windows.replace('line 24\n', 'Metadata fix\n')
        self.series = {
            'patches/series': '# Windows portability\nserver/fix.patch\n',
            'metadata-patches/series': '# Metadata corrections\nserver/fix.patch\n',
        }
        self.patches = {
            'patches/server/fix.patch': self.diff(self.before, self.windows),
            'metadata-patches/server/fix.patch': self.diff(self.windows, self.both),
        }
        self.api = Mock()

    @staticmethod
    def diff(before, after):
        return ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                           fromfile='a/server/example.ts', tofile='b/server/example.ts'))

    def preflight(self, source):
        def file(path, ref, repo=None):
            if repo == check.UPSTREAM:
                self.assertEqual(path, 'server/example.ts')
                self.assertIn(ref, (OLD, NEW))
                return self.before if ref == OLD else source
            self.assertIsNone(repo)
            self.assertEqual(ref, MAIN)
            return (self.series | self.patches)[path]
        self.api.file.side_effect = file
        return check.prepare_patches(self.api, MAIN, OLD, NEW)

    def test_both_stacks_keep_exact_bytes_with_same_entry_name(self):
        self.assertEqual(self.preflight(self.before), {})
        self.api.file.assert_any_call('patches/server/fix.patch', MAIN)
        self.api.file.assert_any_call('metadata-patches/server/fix.patch', MAIN)

    def test_stacks_apply_in_source_preparation_order_on_shared_target(self):
        self.patches['metadata-patches/server/fix.patch'] = self.diff(
            self.windows, self.windows.replace('Windows fix\n', 'Metadata after Windows fix\n'))
        self.assertEqual(self.preflight(self.before), {})

    def test_removal_changes_only_own_series_even_with_same_entry_name(self):
        for root, source, comment in (
            ('patches', self.windows, '# Windows portability\n'),
            ('metadata-patches', self.before.replace('line 24\n', 'Metadata fix\n'), '# Metadata corrections\n'),
        ):
            with self.subTest(root=root):
                self.assertEqual(self.preflight(source), {root + '/server/fix.patch': None, root + '/series': comment})

    def test_upstream_incorporating_both_fixes_removes_both_entries(self):
        self.assertEqual(self.preflight(self.both), {
            'patches/server/fix.patch': None, 'patches/series': '# Windows portability\n',
            'metadata-patches/server/fix.patch': None, 'metadata-patches/series': '# Metadata corrections\n',
        })

    def test_both_stacks_rebase_conflict_free_with_directory_identity(self):
        changed = self.preflight(self.before.replace('line 4\n', 'upstream portability context\n')
                                .replace('line 21\n', 'upstream metadata context\n'))
        self.assertEqual(set(changed), set(self.patches))
        self.assertIn('+Windows fix', changed['patches/server/fix.patch'])
        self.assertIn('upstream portability context', changed['patches/server/fix.patch'])
        self.assertIn('+Metadata fix', changed['metadata-patches/server/fix.patch'])
        self.assertIn('upstream metadata context', changed['metadata-patches/server/fix.patch'])

    def test_metadata_conflict_names_exact_patch_and_stops(self):
        with self.assertRaisesRegex(ValueError, 'Cannot automatically apply patch metadata-patches/server/fix.patch'):
            self.preflight(self.before.replace('line 24\n', 'conflicting upstream metadata fix\n'))
        self.api.write.assert_not_called()

    def test_duplicate_metadata_series_entry_is_rejected(self):
        self.series['metadata-patches/series'] += 'server/fix.patch\n'
        with self.assertRaisesRegex(ValueError, 'Duplicate entries in metadata-patches/series'):
            self.preflight(self.before)

    def test_metadata_is_restricted_to_server_targets(self):
        self.patches['metadata-patches/server/fix.patch'] = self.patches['metadata-patches/server/fix.patch'].replace(
            'server/example.ts', 'machine-learning/example.py')
        with self.assertRaisesRegex(ValueError, 'Unsafe target in patch metadata-patches/server/fix.patch'):
            self.preflight(self.before)

    def test_metadata_series_cannot_escape_its_directory(self):
        for name in ('../patches/server/fix.patch', '/server/fix.patch', 'server/./fix.patch',
                     'server//fix.patch', 'server/.git/fix.patch', 'server/a:b.patch', 'server/a\\b.patch',
                     'machine-learning/fix.patch'):
            with self.subTest(name=name):
                self.series['metadata-patches/series'] = name + '\n'
                with self.assertRaises(ValueError):
                    self.preflight(self.before)


if __name__ == '__main__':
    unittest.main()
