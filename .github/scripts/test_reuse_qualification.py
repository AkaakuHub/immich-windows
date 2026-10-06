"""Offline PR-only reuse, provenance, invalidation and workflow regressions."""
import base64
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import reuse_qualification as reuse
from test_qualified_release import (
    BASE, HEAD, REPO, SOURCE, TREE, VERSION, bundle_entries, provenance, zip_bytes,
)

CURRENT, CURRENT_TREE = 'e' * 40, 'f' * 40


def fixture():
    record, run, jobs, artifact, source, _ = provenance()
    run['id'] = record['runId'] = 100
    run['created_at'] = '2026-10-06T00:00:00Z'
    run['pull_requests'] = [{
        'number': 17,
        'head': {'ref': 'feature', 'sha': HEAD, 'repo': {'id': 44}},
        'base': {'ref': 'main', 'sha': BASE, 'repo': {'id': 44}},
    }]
    artifact['workflow_run']['id'] = 100
    artifact['created_at'] = '2026-10-06T00:10:00Z'
    for job in jobs:
        job.update(id=400, status='completed', started_at='2026-10-06T00:00:00Z', completed_at='2026-10-06T00:11:00Z')
    current_pr = copy.deepcopy(run['pull_requests'][0])
    current_pr['head']['sha'] = '9' * 40
    for field in ('head', 'base'):
        current_pr[field]['repo']['full_name'] = REPO
    current_source = {'sha': CURRENT, 'tree': {'sha': CURRENT_TREE},
                      'parents': [{'sha': BASE}, {'sha': current_pr['head']['sha']}]}
    entries = [{'path': p, 'mode': '100644', 'type': 'blob', 'sha': '1' * 40} for p in (
        'upstream.json', 'dependencies/versions.json', 'runtime/a.ps1', 'packaging/Install.ps1',
        'build/Build-All.ps1', 'tests/Smoke-Windows.ps1', 'patches/series', 'metadata-patches/series',
        'media-patches/libvips/a.patch', '.github/workflows/build-windows.yml',
        '.github/scripts/reuse_qualification.py', '.github/scripts/test_reuse_qualification.py',
        'README.md', 'docs/install.md', 'unknown/new.file',
        '.github/scripts/qualified_release.py', '.github/scripts/publish_qualified.py',
        '.github/scripts/test_qualified_release.py', '.github/scripts/test_publish_qualified.py',
        'docs/development.md',
    )]
    trees = {t: {'sha': t, 'truncated': False, 'tree': copy.deepcopy(entries)} for t in (TREE, CURRENT_TREE)}
    for entry in trees[CURRENT_TREE]['tree']:
        if entry['path'] in reuse.RELEASE_TOOLS:
            entry['sha'] = '2' * 40
    api = mock.Mock(repo=REPO)
    states = {'record': record, 'run': run, 'jobs': jobs, 'artifact': artifact,
              'source': source, 'current': current_source, 'trees': trees,
              'runs': [{'id': 200}, {'id': 100}], 'artifacts': [artifact]}

    def get(path):
        if path == f'git/commits/{CURRENT}': return current_source
        if path == f'git/commits/{SOURCE}': return source
        if path == 'actions/workflows/build-windows.yml': return {'id': 71}
        if path == 'actions/runs/100': return run
        if path.startswith('git/blobs/'):
            sha = path.rsplit('/', 1)[1]
            text = json.dumps({'jobs': {'assemble': {'runs-on': 'windows-2025', 'steps': [{'run': sha}]}, 'validate': {'steps': [{'name': 'Test artifact promotion and rejection policies', 'run': reuse.PYTHON_TEST}]}}})
            return {'sha': sha, 'encoding': 'base64', 'content': base64.b64encode(text.encode()).decode()}
        if path.startswith('git/trees/'):
            return trees[path.split('/')[2].split('?')[0]]
        raise AssertionError(f'Unexpected API get {path}')

    def pages(path, key=None):
        if path == 'releases':
            stamp = '2026-10-05T00:00:00Z'
            return iter([{'tag_name': 'v3.2.2.3', 'draft': False, 'prerelease': False,
                          'published_at': stamp, 'updated_at': stamp,
                          'assets': [{'name': f'immich-windows-v3.2.2.3-{suffix}.zip',
                                      'digest': 'sha256:' + '1' * 64, 'size': 123,
                                      'created_at': stamp, 'updated_at': stamp}
                                     for suffix in ('win-x64', 'native-dependencies')]}])
        if path.startswith('actions/workflows/build-windows.yml/runs?'): return iter(states['runs'])
        if path == 'actions/runs/100/attempts/2/jobs': return iter(jobs)
        if path == 'actions/runs/100/artifacts': return iter(states['artifacts'])
        raise AssertionError(f'Unexpected API pages {path}')

    def download(selected, destination):
        assert selected is artifact
        destination.write_bytes(zip_bytes(bundle_entries(record)))

    api.get.side_effect, api.pages.side_effect, api.download.side_effect = get, pages, download
    return api, {'pull_request': current_pr}, states


class ReuseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.oldcwd = Path.cwd()
        os.chdir(self.temporary.name)
        self.addCleanup(os.chdir, self.oldcwd)
        Path('upstream.json').write_text(json.dumps({'version': 'v3.2.2', 'windowsRevision': 4}), encoding='utf-8')
        Path('event.json').write_text('{}')
        self.env = mock.patch.dict(os.environ, GITHUB_SHA=CURRENT, GITHUB_RUN_ID='200', GITHUB_REF='refs/heads/main', GITHUB_EVENT_PATH=str(Path('event.json').resolve()), CI_ONLY='false')
        self.env.start()
        self.addCleanup(self.env.stop)
        self.git = mock.patch.object(reuse, 'git', return_value=CURRENT)
        self.git.start()
        self.addCleanup(self.git.stop)
        self.api, self.event, self.state = fixture()
        log = '2026-10-06T00:05:00Z Verified upgrade baseline: v3.2.2.3 (v3.2.2, upstream ' + 'a' * 40 + ') -> ' + VERSION + '\n'
        self.log_patch = mock.patch.object(reuse, 'read_job_log', return_value=log)
        self.log_patch.start()
        self.addCleanup(self.log_patch.stop)

    def select(self):
        return reuse.select(self.api, self.event)

    def test_reuses_original_immutable_source_for_release_tools_only(self):
        run, artifact, record = self.select()
        self.assertEqual(record['sourceCommit'], SOURCE)
        self.assertNotEqual(record['sourceCommit'], CURRENT)
        self.assertEqual(run['id'], 100)
        self.assertEqual(artifact['id'], 300)
        self.api.download.assert_called_once()

    def test_all_product_test_and_unknown_inputs_invalidate(self):
        for path in [e['path'] for e in self.state['trees'][CURRENT_TREE]['tree'] if e['path'] not in reuse.RELEASE_TOOLS]:
            with self.subTest(path=path):
                tree = copy.deepcopy(self.state['trees'][CURRENT_TREE])
                entry = next(e for e in self.state['trees'][CURRENT_TREE]['tree'] if e['path'] == path)
                entry['sha'] = '3' * 40
                self.assertIsNone(self.select())
                self.state['trees'][CURRENT_TREE] = tree

    def test_added_deleted_and_mode_changed_inputs_invalidate(self):
        for change in ('added', 'deleted', 'mode', 'type'):
            with self.subTest(change=change):
                original = copy.deepcopy(self.state['trees'][CURRENT_TREE])
                entries = self.state['trees'][CURRENT_TREE]['tree']
                if change == 'added': entries.append({'path': 'new/unknown', 'mode': '100644', 'type': 'blob', 'sha': '8' * 40})
                elif change == 'deleted': entries.pop(0)
                elif change == 'mode': entries[0]['mode'] = '100755'
                else: entries[0]['type'] = 'commit'
                self.assertIsNone(self.select())
                self.state['trees'][CURRENT_TREE] = original

    def test_truncated_trees_fail_closed(self):
        self.state['trees'][CURRENT_TREE]['truncated'] = True
        with self.assertRaisesRegex(ValueError, 'incomplete'): self.select()
        self.api.download.assert_not_called()

    def test_missing_tree_identity_fails_closed(self):
        del self.state['trees'][CURRENT_TREE]['sha']
        with self.assertRaisesRegex(ValueError, 'incomplete'): self.select()

    def test_duplicate_tree_paths_fail_closed(self):
        tree = self.state['trees'][CURRENT_TREE]['tree']
        tree.append(tree[0].copy())
        with self.assertRaisesRegex(ValueError, 'Duplicate'): self.select()

    def test_missing_and_expired_artifacts_fall_back(self):
        for artifacts in ([], [dict(self.state['artifact'], expired=True)]):
            with self.subTest(artifacts=artifacts):
                self.state['artifacts'] = artifacts
                self.assertIsNone(self.select())
        self.api.download.assert_not_called()

    def test_failed_or_pending_latest_run_is_not_bypassed(self):
        for status, conclusion in (('completed', 'failure'), ('in_progress', None), ('completed', 'cancelled')):
            with self.subTest(status=status, conclusion=conclusion):
                self.state['run'].update(status=status, conclusion=conclusion)
                self.assertIsNone(self.select())
        self.api.download.assert_not_called()

    def test_fork_cannot_reuse(self):
        self.event['pull_request']['head']['repo']['full_name'] = 'someone/fork'
        self.assertIsNone(self.select())
        self.api.get.assert_not_called()

    def test_changed_base_does_not_reuse(self):
        self.state['run']['pull_requests'][0]['base']['sha'] = '0' * 40
        self.assertIsNone(self.select())

    def test_other_pr_or_repository_does_not_reuse(self):
        for change in ('number', 'repo'):
            with self.subTest(change=change):
                old = copy.deepcopy(self.state['run']['pull_requests'])
                prior = self.state['run']['pull_requests'][0]
                if change == 'number': prior['number'] = 99
                else: prior['head']['repo']['id'] = 999
                self.assertIsNone(self.select())
                self.state['run']['pull_requests'] = old

    def test_workflow_identity_mismatch_rejected(self):
        self.state['run']['workflow_id'] = 9
        with self.assertRaisesRegex(ValueError, 'Prior PR'): self.select()

    def test_previous_attempt_is_not_reused(self):
        self.state['record']['runAttempt'] = 1
        self.assertIsNone(self.select())

    def test_every_mandatory_job_must_be_uniquely_successful(self):
        for name in reuse.REQUIRED_JOBS:
            for condition in ('missing', 'skipped', 'failure', 'duplicate', 'older'):
                with self.subTest(name=name, condition=condition):
                    original = copy.deepcopy(self.state['jobs'])
                    job = next(j for j in self.state['jobs'] if j['name'] == name)
                    if condition == 'missing': self.state['jobs'].remove(job)
                    elif condition == 'duplicate': self.state['jobs'].append(job.copy())
                    elif condition == 'older': job['run_attempt'] = 1
                    else: job['conclusion'] = condition
                    with self.assertRaisesRegex(ValueError, 'Required'): self.select()
                    self.state['jobs'][:] = original

    def test_artifact_run_head_and_repository_mismatches_rejected(self):
        for field, value in [('id', 999), ('head_sha', '0' * 40), ('repository_id', 999), ('head_repository_id', 999)]:
            with self.subTest(field=field):
                original = self.state['artifact']['workflow_run'][field]
                self.state['artifact']['workflow_run'][field] = value
                with self.assertRaisesRegex(ValueError, 'another run'): self.select()
                self.state['artifact']['workflow_run'][field] = original

    def test_artifact_cannot_come_from_different_attempt_timestamp(self):
        for stamp in ('2026-10-05T23:59:59Z', '2026-10-06T00:11:01Z'):
            self.state['artifact']['created_at'] = stamp
            with self.assertRaisesRegex(ValueError, 'another job attempt'): self.select()

    def test_recorded_source_must_be_real_ordered_pr_merge(self):
        for change in ('sha', 'tree', 'parents'):
            with self.subTest(change=change):
                original = copy.deepcopy(self.state['source'])
                if change == 'sha': self.state['source']['sha'] = CURRENT
                elif change == 'tree': self.state['source']['tree']['sha'] = CURRENT_TREE
                else: self.state['source']['parents'].reverse()
                with self.assertRaisesRegex(ValueError, 'actual tested'): self.select()
                self.state['source'].clear()
                self.state['source'].update(original)

    def test_current_checkout_must_match_event(self):
        self.state['current']['parents'].reverse()
        with self.assertRaisesRegex(ValueError, 'Current PR checkout'): self.select()

    def test_manual_dispatch_never_selects_test_reuse(self):
        for event in ('workflow_dispatch',):
            with self.subTest(event=event), mock.patch.dict(os.environ, GITHUB_EVENT_NAME=event), \
                 mock.patch.object(reuse, 'output') as output, mock.patch.object(reuse, 'summary'), \
                 mock.patch.object(reuse, 'select') as select:
                reuse.plan()
                output.assert_called_once_with({'test_reuse': False})
                select.assert_not_called()

    def test_missing_original_artifact_does_not_trust_prior_reuse_verdict(self):
        self.state['artifacts'] = []
        next(j for j in self.state['jobs'] if j['name'] == 'assemble')['conclusion'] = 'skipped'
        self.assertIsNone(self.select())

    def test_preceding_reuse_run_follows_back_to_original_proof(self):
        original_get, original_pages = self.api.get.side_effect, self.api.pages.side_effect
        prior = copy.deepcopy(self.state['run'])
        prior['id'] = 150
        prior_jobs = copy.deepcopy(self.state['jobs'])
        next(j for j in prior_jobs if j['name'] == 'assemble')['conclusion'] = 'skipped'
        self.state['runs'] = [{'id': 200}, {'id': 150}, {'id': 100}]
        self.api.get.side_effect = lambda p: prior if p == 'actions/runs/150' else original_get(p)
        self.api.pages.side_effect = lambda p, key=None: iter([] if p.endswith('/artifacts') else prior_jobs) if p.startswith('actions/runs/150/') else original_pages(p, key)
        self.assertEqual(self.select()[0]['id'], 100)
        self.api.download.assert_called_once()


class MainReuseTests(unittest.TestCase):
    setUp = ReuseTests.setUp
    def main_fixture(self):
        state = self.state
        state['run'].update(event='push', head_branch='main', head_sha=SOURCE,
                            created_at='2026-10-06T00:00:00Z')
        state['record'].update(event='push', pullRequest=None, headCommit=None, baseCommit=None)
        state['artifact']['workflow_run']['head_sha'] = SOURCE
        self.baseline = mock.patch.object(reuse, 'unchanged_baseline', return_value=True)
        self.baseline_mock = self.baseline.start()
        self.addCleanup(self.baseline.stop)

    def test_main_evidence_is_read_only_and_keeps_original_source(self):
        self.main_fixture()
        run, artifact, record = reuse.select_main(self.api, {})
        self.assertEqual(record['sourceCommit'], SOURCE)
        self.assertNotEqual(record['sourceCommit'], CURRENT)
        self.assertEqual(run['id'], 100)
        self.assertEqual(artifact['id'], 300)
        self.baseline_mock.assert_called_once_with(self.api, VERSION, run, self.state['jobs'])
        self.api.download.assert_called_once()

    def test_main_can_qualify_same_repository_pr_but_not_fork(self):
        self.main_fixture()
        self.assertIsNotNone(reuse.select_main(self.api, self.event))
        self.event['pull_request']['head']['repo']['full_name'] = 'other/fork'
        self.assertIsNone(reuse.select_main(self.api, self.event))

    def test_main_requires_all_inputs_and_stable_external_baseline_before_download(self):
        self.main_fixture()
        self.baseline_mock.return_value = False
        self.assertIsNone(reuse.select_main(self.api, {}))
        self.api.download.assert_not_called()
        self.baseline_mock.return_value = True
        self.state['trees'][CURRENT_TREE]['tree'][0]['sha'] = '8' * 40
        self.assertIsNone(reuse.select_main(self.api, {}))
        self.api.download.assert_not_called()

    def test_main_rejects_old_attempt_wrong_source_and_skipped_gates(self):
        self.main_fixture()
        self.state['record']['runAttempt'] = 1
        self.assertIsNone(reuse.select_main(self.api, {}))
        self.state['record']['runAttempt'] = 2
        self.state['record']['sourceCommit'] = CURRENT
        with self.assertRaisesRegex(ValueError, 'Git object'): reuse.select_main(self.api, {})
        self.state['record']['sourceCommit'] = SOURCE
        self.state['jobs'][0]['conclusion'] = 'skipped'
        with self.assertRaisesRegex(ValueError, 'Mandatory'): reuse.select_main(self.api, {})

    def test_main_never_bypasses_latest_failed_or_pending_run(self):
        self.main_fixture()
        for status, conclusion in [('completed', 'failure'), ('in_progress', None)]:
            self.state['run'].update(status=status, conclusion=conclusion)
            self.assertIsNone(reuse.select_main(self.api, {}))
        self.api.download.assert_not_called()

    def test_push_requires_explicit_ci_only_plan_and_dispatch_never_reuses(self):
        with mock.patch.object(reuse, 'API', return_value=self.api), \
             mock.patch.object(reuse, 'select_main', return_value=None) as select, \
             mock.patch.object(reuse, 'output') as output, mock.patch.object(reuse, 'summary'):
            with mock.patch.dict(os.environ, GITHUB_EVENT_NAME='push', CI_ONLY='false'):
                reuse.plan()
                select.assert_not_called()
                output.assert_called_with({'test_reuse': False})
            with mock.patch.dict(os.environ, GITHUB_EVENT_NAME='push', CI_ONLY='true'):
                reuse.plan()
                select.assert_called_once_with(self.api, {})

    def test_failed_same_pr_evidence_cannot_fall_through_to_main(self):
        Path('event.json').write_text(json.dumps(self.event))
        self.state['run']['conclusion'] = 'failure'
        with mock.patch.dict(os.environ, GITHUB_EVENT_NAME='pull_request', CI_ONLY='true'), \
             mock.patch.object(reuse, 'API', return_value=self.api), \
             mock.patch.object(reuse, 'select_main') as main, \
             mock.patch.object(reuse, 'output'), mock.patch.object(reuse, 'summary'):
            reuse.plan()
            main.assert_not_called()


class WorkflowInputTests(unittest.TestCase):
    def setUp(self):
        self.text = (Path(__file__).parents[1] / 'workflows/build-windows.yml').read_text(encoding='utf-8')
        self.original = reuse.workflow_inputs(self.text)

    def test_corepack_cache_only_change_is_equivalent(self):
        old = self.text.replace('build-downloads-corepack-v1-', 'build-downloads-')
        old = '\n'.join(line for line in old.splitlines()
                        if 'restore-keys: build-downloads-' not in line and 'COREPACK_HOME:' not in line)
        # Removing COREPACK_HOME leaves an empty YAML env node: remove that node.
        old = old.replace('        env:\n          # Keep the pinned pnpm package in the existing download cache.\n', '')
        self.assertEqual(self.original, reuse.workflow_inputs(old))

    def test_every_execution_change_remains_an_input(self):
        mutations = [
            ('runs-on: windows-2025', 'runs-on: windows-2022'),
            ('contents: read', 'contents: write'),
            ('shell: pwsh', 'shell: bash'),
            ('-SkipNativeDependencies', '-SkipNativeDependencies -SkipTests'),
            ('./tests/actions/Test-RevisionUpgrade.ps1', './tests/actions/Different.ps1'),
            ('COREPACK_HOME: ${{ github.workspace }}/.cache/corepack', 'COREPACK_HOME: /other/cache'),
            ('          path: .cache', '          path: .tools'),
            ('actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9', 'actions/cache/restore@main'),
            ('actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09', 'actions/checkout@main'),
            ('ref: ${{ needs.plan.outputs.checkout || github.sha }}', 'ref: main'),
            ("if: needs.plan.outputs.test_reuse != 'true' && (", "if: false && ("),
            ('needs: [plan, validate]', 'needs: [plan]'),
            ('GH_TOKEN: ${{ github.token }}', 'GH_TOKEN: different'),
        ]
        for before, after in mutations:
            with self.subTest(after=after):
                self.assertIn(before, self.text)
                self.assertNotEqual(self.original, reuse.workflow_inputs(self.text.replace(before, after)))
        self.assertNotEqual(self.original, reuse.workflow_inputs(self.text + '\n  new-job:\n    runs-on: windows-2025\n    steps: [{run: dangerous}]\n'))

    def test_unknown_cache_settings_and_steps_are_not_ignored(self):
        changed = self.text.replace('          path: .cache\n', '          path: .cache\n          enableCrossOsArchive: true\n', 1)
        self.assertNotEqual(self.original, reuse.workflow_inputs(changed))
        changed = self.text.replace('      - name: Build and qualify Windows package', '      - run: echo added\n      - name: Build and qualify Windows package')
        self.assertNotEqual(self.original, reuse.workflow_inputs(changed))

    def test_duplicate_keys_aliases_merge_keys_and_unsafe_tags_fail_closed(self):
        import yaml
        for text in [
            'jobs: {}\njobs: {}',
            'jobs: {assemble: {runs-on: windows-2025, runs-on: ubuntu-24.04}}',
            'shared: &a {}\njobs: {assemble: *a}',
            'jobs: {assemble: {<<: {runs-on: windows-2025}}}',
            'jobs: !!python/object:os.system {}',
        ]:
            with self.subTest(text=text), self.assertRaises((ValueError, yaml.YAMLError)):
                reuse.workflow_inputs(text)

    def test_orchestration_outputs_permissions_and_new_steps_remain_inputs(self):
        for before, after in [
            ('version: ${{ steps.plan.outputs.version }}', 'version: v99.0.0.0'),
            ('      pull-requests: read', '      pull-requests: write'),
            ('  cancel-in-progress:', '  arbitrary-setting:'),
            ('      - name: Select existing qualification or a fresh build',
             '      - run: echo new-plan-step\n      - name: Select existing qualification or a fresh build'),
            ('      - name: Test current CI scripts and workflow contracts',
             '      - run: echo new-ci-step\n      - name: Test current CI scripts and workflow contracts'),
        ]:
            with self.subTest(after=after):
                self.assertNotEqual(self.original, reuse.workflow_inputs(self.text.replace(before, after)))

    def test_removing_every_current_ci_test_lane_is_rejected(self):
        import yaml
        data = yaml.load(self.text, Loader=yaml.BaseLoader)
        del data['jobs']['ci-tools']
        data['jobs']['publish']['needs'].remove('ci-tools')
        data['jobs']['publish']['if'] = data['jobs']['publish']['if'].replace(" && needs.ci-tools.result == 'success'", '')
        with self.assertRaisesRegex(ValueError, 'Missing current CI'):
            reuse.workflow_inputs(yaml.safe_dump(data))

    def test_scalar_types_and_yaml_11_boolean_spellings_do_not_collapse(self):
        for first, second in [('false', '0'), ('true', '1'), ('yes', 'true'), ('no', 'false'), ('off', 'no')]:
            with self.subTest(first=first, second=second):
                a = self.text + f'\nenv: {{REVIEW_SENTINEL: {first}}}\n'
                b = self.text + f'\nenv: {{REVIEW_SENTINEL: {second}}}\n'
                self.assertNotEqual(reuse.workflow_inputs(a), reuse.workflow_inputs(b))

    def test_ci_tests_run_independently_and_publication_waits_for_them(self):
        import yaml
        jobs = yaml.safe_load(self.text)['jobs']
        tooling = jobs['ci-tools']
        self.assertEqual(tooling['runs-on'], 'ubuntu-24.04')
        self.assertEqual(tooling['if'], "${{ !cancelled() && needs.plan.result == 'success' }}")
        self.assertIn({'name': 'Test current CI scripts and workflow contracts', 'run': reuse.PYTHON_TEST}, tooling['steps'])
        self.assertIn('ci-tools', jobs['publish']['needs'])
        self.assertIn("needs.ci-tools.result == 'success'", jobs['publish']['if'])
        self.assertIn("needs.plan.outputs.test_reuse != 'true'", jobs['validate']['if'])

    def test_precompressed_artifact_transport_does_not_requalify_product(self):
        old = self.text.replace('          compression-level: 0\n', '')
        self.assertEqual(self.original, reuse.workflow_inputs(old))
        self.assertEqual(self.text.count('compression-level: 0'), 2)


class BaselineInputTests(unittest.TestCase):
    def setUp(self):
        self.run = {'created_at': '2026-10-06T00:00:00Z', 'run_attempt': 2}
        self.jobs = [{'name': 'assemble', 'id': 400, 'run_attempt': 2, 'status': 'completed', 'conclusion': 'success'}]
        log = '2026-10-06T00:05:00Z Verified upgrade baseline: v3.2.2.3 (v3.2.2, upstream ' + 'a' * 40 + ') -> ' + VERSION + '\n'
        self.logs = self.enterContext(mock.patch.object(reuse, 'read_job_log', return_value=log))
        stamp = '2026-10-05T00:00:00Z'
        self.release = {'tag_name': 'v3.2.2.3', 'draft': False, 'prerelease': False,
                        'published_at': stamp, 'updated_at': stamp,
                        'assets': [{'name': f'immich-windows-v3.2.2.3-{suffix}.zip',
                                    'digest': 'sha256:' + '1' * 64, 'size': 123,
                                    'created_at': stamp, 'updated_at': stamp}
                                   for suffix in ('win-x64', 'native-dependencies')]}
        self.api = mock.Mock()
        self.api.pages.side_effect = lambda path: iter([self.release])

    def test_unchanged_digest_verified_preceding_baseline_is_eligible(self):
        self.assertTrue(reuse.unchanged_baseline(self.api, VERSION, self.run, self.jobs))

    def test_new_or_updated_baseline_release_or_asset_invalidates(self):
        for target, key in [(self.release, 'published_at'), (self.release, 'updated_at'),
                            (self.release['assets'][0], 'created_at'), (self.release['assets'][1], 'updated_at')]:
            with self.subTest(key=key):
                original = target[key]
                target[key] = '2026-10-06T00:01:00Z'
                self.assertFalse(reuse.unchanged_baseline(self.api, VERSION, self.run, self.jobs))
                target[key] = original
        self.release['assets'][0]['digest'] = None
        self.assertFalse(reuse.unchanged_baseline(self.api, VERSION, self.run, self.jobs))

    def test_missing_ambiguous_or_nonpreceding_baseline_fails_closed(self):
        self.release['assets'].append(copy.deepcopy(self.release['assets'][0]))
        self.assertFalse(reuse.unchanged_baseline(self.api, VERSION, self.run, self.jobs))
        self.release['assets'].pop()
        self.release['tag_name'] = VERSION
        self.assertFalse(reuse.unchanged_baseline(self.api, VERSION, self.run, self.jobs))
    def test_deleted_higher_baseline_cannot_be_replaced_with_old_lower_release(self):
        self.logs.return_value = self.logs.return_value.replace('v3.2.2.3 (', 'v3.2.2.2 (')
        self.assertFalse(reuse.unchanged_baseline(self.api, VERSION, self.run, self.jobs))

    def test_missing_or_ambiguous_original_log_fails_closed(self):
        original = self.logs.return_value
        for value in ('', original + original):
            self.logs.return_value = value
            self.assertFalse(reuse.unchanged_baseline(self.api, VERSION, self.run, self.jobs))


class FinalGateTests(unittest.TestCase):
    def test_final_gate_keeps_early_metadata_and_rejects_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            assets = {name: b'tested' for name in reuse.filenames(VERSION)}
            for name, content in assets.items(): (root / name).write_bytes(content)
            record = {'version': VERSION, 'sourceCommit': SOURCE, 'sourceTree': TREE,
                      'assets': {name: reuse.sha256(root / name) for name in assets}}
            metadata = json.dumps(record).encode('utf-8')
            (root / 'qualification.json').write_bytes(metadata)
            def git(*args):
                return {('status', '--porcelain', '--untracked-files=no'): '',
                        ('rev-parse', 'HEAD'): SOURCE, ('rev-parse', 'HEAD^{tree}'): TREE}[args]
            with mock.patch.object(reuse, 'git', side_effect=git):
                reuse.finish(root)
                self.assertEqual((root / 'qualification.json').read_bytes(), metadata)
                (root / 'Install.cmd').write_bytes(b'changed after snapshot')
                with self.assertRaisesRegex(ValueError, 'asset changed'): reuse.finish(root)
            with mock.patch.object(reuse, 'git', return_value=' M runtime/file'):
                with self.assertRaisesRegex(ValueError, 'Tracked source changed'): reuse.finish(root)


class WorkflowTests(unittest.TestCase):
    def test_record_precedes_expensive_installs_and_upload_follows_final_gate(self):
        workflow = (Path(__file__).parents[1] / 'workflows/build-windows.yml').read_text(encoding='utf-8')
        record = workflow.index('Stage source metadata and asset hashes before installation tests')
        install = workflow.index('Install, upgrade and test both Windows scopes')
        finish = workflow.index('Verify tested source and staged asset hashes remained unchanged')
        upload = workflow.index('name: qualified-windows-package-v1')
        self.assertLess(record, install)
        self.assertLess(install, finish)
        self.assertLess(finish, upload)
        self.assertIn("if: needs.plan.outputs.test_reuse != 'true'", workflow)
        self.assertIn("python -m unittest discover -s .github/scripts -p 'test_*.py' -v", workflow)
        # The PR shortcut does not become the existing release-promotion output.
        self.assertIn('reuse: ${{ steps.plan.outputs.reuse }}', workflow)
        self.assertIn('test_reuse: ${{ steps.test-reuse.outputs.test_reuse }}', workflow)


if __name__ == '__main__':
    unittest.main()
