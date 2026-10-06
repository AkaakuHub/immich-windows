"""Offline PR-only reuse, provenance, invalidation and workflow regressions."""
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
    run['pull_requests'] = [{
        'number': 17,
        'head': {'ref': 'feature', 'sha': HEAD, 'repo': {'id': 44}},
        'base': {'ref': 'main', 'sha': BASE, 'repo': {'id': 44}},
    }]
    artifact['workflow_run']['id'] = 100
    artifact['created_at'] = '2026-10-06T00:10:00Z'
    for job in jobs:
        job.update(status='completed', started_at='2026-10-06T00:00:00Z', completed_at='2026-10-06T00:11:00Z')
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
        if path.startswith('git/trees/'):
            return trees[path.split('/')[2].split('?')[0]]
        raise AssertionError(f'Unexpected API get {path}')

    def pages(path, key=None):
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
        self.env = mock.patch.dict(os.environ, GITHUB_SHA=CURRENT, GITHUB_RUN_ID='200')
        self.env.start()
        self.addCleanup(self.env.stop)
        self.git = mock.patch.object(reuse, 'git', return_value=CURRENT)
        self.git.start()
        self.addCleanup(self.git.stop)
        self.api, self.event, self.state = fixture()

    def select(self):
        return reuse.select(self.api, self.event)

    def test_reuses_original_immutable_source_for_release_tools_only(self):
        run, artifact, record = self.select()
        self.assertEqual(record['sourceCommit'], SOURCE)
        self.assertNotEqual(record['sourceCommit'], CURRENT)
        self.assertEqual(run['id'], 100)
        self.assertEqual(artifact['id'], 300)
        self.api.download.assert_called_once()

    def test_all_other_inputs_invalidate_including_workflow_and_selector(self):
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

    def test_non_pr_commands_never_select_test_reuse(self):
        for event in ('push', 'workflow_dispatch'):
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
