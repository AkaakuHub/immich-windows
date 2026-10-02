"""Offline regression tests for the artifact-promotion trust boundary.

Run with: python -m unittest discover -s .github/scripts -p 'test_*.py' -v
All archive bytes and GitHub responses are local fixtures. Unexpected network
requests or Git commands fail the test rather than consulting external state.
"""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
import warnings
import zipfile


SPEC = importlib.util.spec_from_file_location(
    'qualified_release', Path(__file__).with_name('qualified_release.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

VERSION = 'v3.2.2.4'
REPO = 'example/immich-windows'
SOURCE, TREE, HEAD, BASE, MERGED = (character * 40 for character in 'abcde')


def zip_bytes(entries):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in entries:
            archive.writestr(name, content)
    return stream.getvalue()


def provenance(event='pull_request'):
    """A PR tests its synthetic merge; main tests the triggering commit."""
    is_pr = event == 'pull_request'
    source_sha = SOURCE if is_pr else MERGED
    record = {
        'schemaVersion': 1, 'repository': REPO, 'version': VERSION,
        'runId': 100 if is_pr else 200, 'runAttempt': 2, 'event': event,
        'sourceCommit': source_sha, 'sourceTree': TREE,
        'pullRequest': 17 if is_pr else None,
        'headCommit': HEAD if is_pr else None,
        'baseCommit': BASE if is_pr else None,
    }
    run = {
        'id': record['runId'], 'run_attempt': 2,
        'repository': {'full_name': REPO, 'id': 44},
        'head_repository': {'full_name': REPO, 'id': 44},
        'head_sha': HEAD if is_pr else MERGED,
        'head_branch': 'feature' if is_pr else 'main',
        'path': release.WORKFLOW, 'workflow_id': 71, 'event': event,
        'status': 'completed', 'conclusion': 'success',
    }
    jobs = [{'name': name, 'conclusion': 'success', 'run_attempt': 2}
            for name in sorted(release.REQUIRED_JOBS)]
    artifact = {
        'id': 300, 'name': release.ARTIFACT, 'expired': False,
        'workflow_run': {'id': run['id'], 'head_sha': run['head_sha'],
                         'repository_id': 44, 'head_repository_id': 44},
        'digest': 'sha256:' + '0' * 64, 'size_in_bytes': 1,
    }
    source = {'sha': source_sha, 'tree': {'sha': TREE},
              'parents': [{'sha': BASE}, {'sha': HEAD}]}
    pr = {
        'number': 17, 'merged': True, 'merge_commit_sha': MERGED,
        'base': {'ref': 'main', 'sha': BASE},
        'head': {'sha': HEAD, 'repo': {'full_name': REPO}},
    }
    return record, run, jobs, artifact, source, pr


def bundle_entries(record=None, manifest_changes=None):
    record = copy.deepcopy(record or provenance()[0])
    version = record['version']
    manifest = {'packageVersion': version, 'sourceCommit': record['sourceCommit']}
    manifest.update(manifest_changes or {})
    assets = {
        f'immich-windows-{version}-win-x64.zip': zip_bytes([
            (f'immich-windows-{version}-win-x64/manifest.json', json.dumps(manifest)),
            (f'immich-windows-{version}-win-x64/app.txt', 'fixture application'),
        ]),
        f'immich-windows-{version}-native-dependencies.zip': zip_bytes([
            ('dependencies/fixture.txt', 'fixture dependency')]),
        f'immich-windows-{version}-migration-tools.zip': zip_bytes([
            ('migration/fixture.txt', 'fixture migration tool')]),
        'Install.cmd': b'@echo off\r\nrem Offline test fixture, never executed\r\n',
    }
    record['assets'] = {name: hashlib.sha256(content).hexdigest()
                        for name, content in assets.items()}
    return list(assets.items()) + [('qualification.json', json.dumps(record))]


class OfflineTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.urlopen = self.enterContext(mock.patch.object(
            release.urllib.request, 'urlopen', side_effect=AssertionError('Unexpected network request')))
        self.opener = self.enterContext(mock.patch.object(
            release.urllib.request, 'build_opener', side_effect=AssertionError('Unexpected network request')))
        self.git = self.enterContext(mock.patch.object(
            release, 'git', side_effect=AssertionError('Unexpected Git command')))
        self.enterContext(mock.patch.dict(os.environ, {
            'GITHUB_REPOSITORY': REPO, 'GH_TOKEN': 'offline-test-token',
            'GITHUB_RUN_ID': '200', 'GITHUB_RUN_ATTEMPT': '2',
            'GITHUB_SHA': MERGED, 'GITHUB_REF': 'refs/heads/main',
            'GITHUB_EVENT_NAME': 'push',
            'GITHUB_OUTPUT': str(self.directory / 'output'),
            'GITHUB_STEP_SUMMARY': str(self.directory / 'summary'),
            'QUALIFIED_RUN_ID': '', 'QUALIFIED_ARTIFACT_ID': '',
            'QUALIFIED_ARTIFACT_DIGEST': '', 'COMPONENT': '',
        }, clear=True))

    def transport(self, content):
        self.opener.side_effect = None
        self.opener.return_value.open.side_effect = lambda *args, **kwargs: io.BytesIO(content)

    def outputs(self):
        return dict(line.split('=', 1) for line in
                    (self.directory / 'output').read_text().splitlines())


class BundleTests(OfflineTestCase):
    def check_bundle(self, entries):
        archive = self.directory / 'bundle.zip'
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            archive.write_bytes(zip_bytes(entries))
        return release.validate_bundle(archive, self.directory / 'assets', VERSION)

    def test_valid_bundle_extracts_only_the_four_hashed_assets(self):
        entries = bundle_entries()
        record = self.check_bundle(entries)
        self.assertEqual(record['sourceCommit'], SOURCE)
        self.assertEqual(set(record['assets']), release.filenames(VERSION))
        self.assertEqual({path.name for path in (self.directory / 'assets').iterdir()},
                         release.filenames(VERSION))
        for name, content in entries[:-1]:
            self.assertEqual((self.directory / 'assets' / name).read_bytes(), content)

    def test_exact_asset_names_reject_missing_extra_duplicate_and_paths(self):
        good = bundle_entries()
        for label, entries in {
            'missing': good[1:],
            'extra': good + [('unexpected.exe', b'not allowed')],
            'duplicate': good + [good[0]],
            'parent traversal': [('../Install.cmd', good[3][1])] + good[:3] + good[4:],
            'absolute': [('/Install.cmd', good[3][1])] + good[:3] + good[4:],
            'nested': [('folder/Install.cmd', good[3][1])] + good[:3] + good[4:],
            'wrong version': [(good[0][0].replace(VERSION, 'v3.2.2.3'), good[0][1])] + good[1:],
        }.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.check_bundle(entries)
        self.assertFalse((self.directory / 'Install.cmd').exists())

    def test_symlink_entry_is_rejected(self):
        entries = bundle_entries()
        link = zipfile.ZipInfo('Install.cmd')
        link.create_system = 3
        link.external_attr = 0o120777 << 16
        entries[3] = (link, '../outside')
        with self.assertRaises(ValueError):
            self.check_bundle(entries)

    def test_per_entry_and_aggregate_uncompressed_size_limits(self):
        entries = bundle_entries()
        sizes = [len(value.encode() if isinstance(value, str) else value)
                 for _, value in entries]
        for maximum in (max(sizes) - 1, sum(sizes) - 1):
            with self.subTest(maximum=maximum), mock.patch.object(release, 'MAX_BYTES', maximum):
                with self.assertRaises(ValueError):
                    self.check_bundle(entries)

    def test_qualification_record_size_limit(self):
        entries = bundle_entries()
        record = json.loads(entries[-1][1])
        record['padding'] = 'x' * (64 * 1024)
        entries[-1] = ('qualification.json', json.dumps(record))
        with self.assertRaises(ValueError):
            self.check_bundle(entries)

    def test_record_schema_version_asset_list_and_hash_are_verified(self):
        for label in ('schema', 'version', 'missing asset', 'extra asset', 'hash'):
            entries = bundle_entries()
            record = json.loads(entries[-1][1])
            if label == 'schema':
                record['schemaVersion'] = 99
            elif label == 'version':
                record['version'] = 'v3.2.2.3'
            elif label == 'missing asset':
                record['assets'].pop('Install.cmd')
            elif label == 'extra asset':
                record['assets']['unexpected.exe'] = '0' * 64
            else:
                record['assets']['Install.cmd'] = '0' * 64
            entries[-1] = ('qualification.json', json.dumps(record))
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.check_bundle(entries)

    def test_asset_bytes_cannot_change_after_qualification(self):
        entries = bundle_entries()
        entries[3] = ('Install.cmd', b'changed after hashing')
        with self.assertRaisesRegex(ValueError, 'hash'):
            self.check_bundle(entries)

    def test_packaged_manifest_version_and_source_match_qualification(self):
        for changes in ({'packageVersion': 'v3.2.2.3'}, {'sourceCommit': 'f' * 40}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.check_bundle(bundle_entries(manifest_changes=changes))

    def test_package_manifest_size_limit(self):
        entries = bundle_entries(manifest_changes={'padding': 'x' * (4 * 1024 * 1024)})
        with self.assertRaises(ValueError):
            self.check_bundle(entries)

    def test_intact_old_version_bundle_is_valid_evidence_but_not_reusable(self):
        record = provenance()[0]
        record['version'] = 'v3.2.2.3'
        with self.assertRaises(release.NotReusable):
            self.check_bundle(bundle_entries(record))


class DownloadTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.content = zip_bytes(bundle_entries())
        self.artifact = provenance()[3]
        self.artifact.update(size_in_bytes=len(self.content),
                             digest='sha256:' + hashlib.sha256(self.content).hexdigest())
        self.api = release.API()
        self.destination = self.directory / 'download.zip'

    def test_download_checks_the_real_archive_digest(self):
        self.transport(self.content)
        self.api.download(self.artifact, self.destination)
        self.assertEqual(self.destination.read_bytes(), self.content)

    def test_invalid_or_mismatched_digest_is_rejected(self):
        self.transport(self.content)
        for digest in (None, '', 'sha256:short', 'md5:' + '0' * 64, 'sha256:' + '0' * 64):
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                self.api.download(dict(self.artifact, digest=digest), self.destination)

    def test_invalid_declared_size_is_rejected_before_download(self):
        for size in (0, -1, release.MAX_BYTES + 1):
            with self.subTest(size=size), self.assertRaises(ValueError):
                self.api.download(dict(self.artifact, size_in_bytes=size), self.destination)
        self.opener.assert_not_called()

    def test_streamed_size_limit_does_not_trust_declared_size(self):
        self.transport(self.content)
        with mock.patch.object(release, 'MAX_BYTES', len(self.content) - 1):
            with self.assertRaises(ValueError):
                self.api.download(dict(self.artifact, size_in_bytes=1), self.destination)

    def test_signed_redirect_does_not_forward_the_authorization_header(self):
        self.opener.side_effect = None
        location = 'https://storage.example.test/signed-artifact'
        self.opener.return_value.open.side_effect = urllib.error.HTTPError(
            self.api.root, 302, 'Found', {'Location': location}, None)
        self.urlopen.side_effect = lambda *args, **kwargs: io.BytesIO(self.content)
        self.api.download(self.artifact, self.destination)
        self.urlopen.assert_called_once_with(location, timeout=60)
        request = self.opener.return_value.open.call_args.args[0]
        self.assertEqual(request.get_header('Authorization'), 'Bearer offline-test-token')

    def test_non_https_redirect_and_http_errors_are_not_accepted(self):
        self.opener.side_effect = None
        for code, location, error_type in ((302, 'http://storage.example.test/file', ValueError),
                                            (403, None, urllib.error.HTTPError)):
            self.opener.return_value.open.side_effect = urllib.error.HTTPError(
                self.api.root, code, 'Rejected', {'Location': location}, None)
            with self.subTest(code=code), self.assertRaises(error_type):
                self.api.download(self.artifact, self.destination)
        self.urlopen.assert_not_called()


class ProvenanceTests(unittest.TestCase):
    def validate(self, values, target_tree=TREE, pr=True):
        record, run, jobs, artifact, source, pull_request = values
        release.validate_provenance(record, run, jobs, artifact, source,
                                    target_tree, REPO, pull_request if pr else None)

    def test_synthetic_pr_merge_and_main_builds_are_valid(self):
        self.validate(provenance())
        for event in ('push', 'workflow_dispatch'):
            with self.subTest(event=event):
                self.validate(provenance(event), pr=False)

    def test_repository_workflow_run_and_artifact_provenance_are_required(self):
        changes = (
            (0, ('repository',), 'attacker/fork'),
            (1, ('repository', 'full_name'), 'attacker/fork'),
            (1, ('head_repository', 'full_name'), 'attacker/fork'),
            (1, ('path',), '.github/workflows/untrusted.yml'),
            (1, ('status',), 'in_progress'),
            (1, ('conclusion',), 'failure'),
            (0, ('runId',), 99),
            (0, ('runAttempt',), 1),
            (3, ('workflow_run', 'id'), 99),
            (3, ('workflow_run', 'head_sha'), 'f' * 40),
            (3, ('workflow_run', 'repository_id'), 999),
            (3, ('workflow_run', 'head_repository_id'), 999),
            (1, ('repository', 'id'), 999),
            (1, ('head_repository', 'id'), 999),
            (3, ('name',), 'unqualified-package'),
            (3, ('expired',), True),
        )
        for index, path, value in changes:
            values = provenance()
            target = values[index]
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(object=index, field=path, value=value), self.assertRaises(ValueError):
                self.validate(values)

    def test_every_required_job_must_succeed_in_the_exact_attempt(self):
        for name in sorted(release.REQUIRED_JOBS):
            for state in ('missing', 'skipped', 'failure', 'cancelled', 'old attempt'):
                values = provenance()
                jobs = values[2]
                job = next(job for job in jobs if job['name'] == name)
                if state == 'missing':
                    jobs.remove(job)
                elif state == 'old attempt':
                    job['run_attempt'] = 1
                else:
                    job['conclusion'] = state
                with self.subTest(job=name, state=state), self.assertRaises(ValueError):
                    self.validate(values)

    def test_git_object_ids_and_authoritative_source_tree_are_verified(self):
        for index, path, value in (
            (0, ('sourceCommit',), 'not-a-commit'),
            (0, ('sourceTree',), 'not-a-tree'),
            (4, ('sha',), 'f' * 40),
            (4, ('tree', 'sha'), 'f' * 40),
        ):
            values = provenance()
            target = values[index]
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(field=path), self.assertRaises(ValueError):
                self.validate(values)
        with self.assertRaises(ValueError):
            self.validate(provenance(), target_tree='f' * 40)

    def test_pr_must_be_the_current_merged_same_repository_main_pr(self):
        changes = (
            (0, ('event',), 'push'),
            (1, ('event',), 'pull_request_target'),
            (5, ('merged',), False),
            (5, ('base', 'ref'), 'release'),
            (5, ('head', 'repo', 'full_name'), 'attacker/fork'),
            (0, ('pullRequest',), 18),
            (0, ('headCommit',), 'f' * 40),
            (5, ('head', 'sha'), 'f' * 40),
            (5, ('base', 'sha'), 'f' * 40),
        )
        for index, path, value in changes:
            values = provenance()
            target = values[index]
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(object=index, field=path), self.assertRaises(ValueError):
                self.validate(values)

    def test_pr_checkout_must_have_exact_ordered_base_and_head_parents(self):
        for parents in ([], [HEAD], [HEAD, BASE], [BASE, 'f' * 40], [BASE, HEAD, 'f' * 40]):
            values = provenance()
            values[4]['parents'] = [{'sha': sha} for sha in parents]
            with self.subTest(parents=parents), self.assertRaises(ValueError):
                self.validate(values)

    def test_main_build_must_test_its_own_main_head(self):
        for field, value in (('head_sha', 'f' * 40), ('head_branch', 'feature'),
                             ('event', 'pull_request'), ('event', 'schedule')):
            values = provenance('push')
            values[1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate(values, pr=False)


class ReleasePolicyTests(OfflineTestCase):
    def api_with_releases(self, releases):
        api = mock.Mock()
        api.pages.return_value = iter(releases)
        return api

    def test_version_must_include_the_windows_revision(self):
        self.assertEqual(len(release.filenames(VERSION)), 4)
        for version in ('3.2.2.4', 'v3.2.2', 'v3.2.2.4-beta', '../v3.2.2.4', 'v3.2.2.4\n'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.filenames(version)

    def test_ci_only_exemption_is_deliberately_narrow(self):
        for paths in ([], ['.github/workflows/build-windows.yml'], ['.github/scripts/qualified_release.py'],
                      ['docs/development.md'], ['.github/test', 'docs/development.md']):
            with self.subTest(paths=paths):
                self.assertTrue(release.ci_only(paths))
        for path in ('README.md', 'docs/installation.md', 'docs/development.md.bak',
                     'runtime/Start.ps1', 'packaging/package.ps1', 'tests/Smoke-Windows.ps1',
                     'dependencies/pins.json', 'upstream.json', 'unknown.txt'):
            with self.subTest(path=path):
                self.assertFalse(release.ci_only(['.github/workflows/build.yml', path]))

    def test_new_version_publishes_without_comparing_git_trees(self):
        api = self.api_with_releases([
            {'draft': False, 'tag_name': 'v3.2.2.3'},
            {'draft': False, 'tag_name': 'v3.2.2'},
            {'draft': False, 'tag_name': 'nightly'},
            {'draft': True, 'tag_name': 'v99.0.0.0'},
        ])
        self.assertTrue(release.release_policy(api, VERSION))
        api.pages.assert_called_once_with('releases')
        self.git.assert_not_called()

    def test_older_than_any_published_revision_is_rejected_numerically(self):
        for tag in ('v3.2.2.5', 'v3.2.2.10', 'v3.3.0', 'v10.0.0.0'):
            api = self.api_with_releases([{'draft': False, 'tag_name': tag}])
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.release_policy(api, VERSION)
        self.git.assert_not_called()

    def test_existing_draft_is_not_overwritten(self):
        with self.assertRaises(ValueError):
            release.release_policy(self.api_with_releases([
                {'draft': True, 'tag_name': VERSION}]), VERSION)
        self.git.assert_not_called()

    def test_existing_version_allows_only_ci_or_developer_documentation_changes(self):
        for changed in ('', '.github/scripts/qualified_release.py\0docs/development.md\0'):
            self.git.side_effect = ['', changed]
            with self.subTest(changed=changed):
                self.assertFalse(release.release_policy(self.api_with_releases([
                    {'draft': False, 'tag_name': VERSION}]), VERSION))
                self.assertEqual(self.git.call_args_list[-2:], [
                    mock.call('fetch', '--no-tags', 'origin', f'refs/tags/{VERSION}'),
                    mock.call('diff', '--no-renames', '--name-only', '-z', 'FETCH_HEAD', 'HEAD'),
                ])

    def test_existing_version_with_shipped_or_test_inputs_changed_requires_a_revision(self):
        for path in ('README.md', 'runtime/Start.ps1', 'tests/Smoke-Windows.ps1',
                     'docs/installation.md', 'upstream.json',
                     'runtime/shipped.ps1\0.github/moved.ps1\0'):
            self.git.side_effect = ['', path]
            with self.subTest(path=path), self.assertRaises(ValueError):
                release.release_policy(self.api_with_releases([
                    {'draft': False, 'tag_name': VERSION}]), VERSION)


class FixtureAPI(release.API):
    """Strict local responses; archive downloads still use production logic."""
    def __init__(self):
        super().__init__()
        self.objects = {}
        self.collections = {'releases': []}
        self.calls = []

    def get(self, path):
        self.calls.append(('get', path))
        if path not in self.objects:
            raise AssertionError(f'Unexpected API GET: {path}')
        if isinstance(self.objects[path], Exception):
            raise self.objects[path]
        return copy.deepcopy(self.objects[path])

    def pages(self, path, key=None):
        self.calls.append(('pages', path, key))
        if path not in self.collections:
            raise AssertionError(f'Unexpected API collection: {path}')
        return iter(copy.deepcopy(self.collections[path]))


class ControlFlowTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        previous = Path.cwd()
        os.chdir(self.directory)
        self.addCleanup(os.chdir, previous)
        Path('upstream.json').write_text(json.dumps({'version': 'v3.2.2', 'windowsRevision': 4}))
        self.api = FixtureAPI()
        self.enterContext(mock.patch.object(release, 'API', return_value=self.api))
        self.git.side_effect = self.local_git

    @staticmethod
    def local_git(*args):
        if args == ('rev-parse', 'HEAD^{tree}'):
            return TREE
        raise AssertionError(f'Unexpected Git command: {args}')

    def install_fixture(self, event='pull_request', mutate=None):
        values = provenance(event)
        if mutate:
            mutate(values)
        record, run, jobs, artifact, source, pr = values
        self.content = zip_bytes(bundle_entries(record))
        artifact.update(size_in_bytes=len(self.content),
                        digest='sha256:' + hashlib.sha256(self.content).hexdigest())
        self.transport(self.content)
        self.api.collections[f'commits/{MERGED}/pulls'] = [{'number': pr['number']}]
        self.api.objects[f"pulls/{pr['number']}"] = pr
        self.api.collections[
            f"actions/workflows/build-windows.yml/runs?event=pull_request&head_sha={pr['head']['sha']}"] = [run]
        self.api.collections[f"actions/runs/{run['id']}/artifacts"] = [artifact]
        self.api.collections[f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"] = jobs
        self.api.objects[f"actions/runs/{run['id']}"] = run
        self.api.objects['actions/workflows/build-windows.yml'] = {'id': 71}
        self.api.objects[f"git/commits/{record['sourceCommit']}"] = source
        return values

    def select_pr_artifact(self, artifact):
        os.environ.update(QUALIFIED_RUN_ID='100', QUALIFIED_ARTIFACT_ID=str(artifact['id']),
                          QUALIFIED_ARTIFACT_DIGEST=artifact['digest'])

    def test_plan_reuses_a_valid_pr_bundle_without_running_any_build(self):
        record, run, _, artifact, _, _ = self.install_fixture()
        release.plan()
        outputs = self.outputs()
        self.assertEqual(outputs, {
            'version': VERSION, 'publish': 'true', 'reuse': 'true',
            'artifact_id': str(artifact['id']), 'artifact_digest': artifact['digest'],
            'run_id': str(run['id']), 'source_commit': record['sourceCommit'],
        })
        self.opener.return_value.open.assert_called_once()
        self.assertIn('No repeated build or tests', (self.directory / 'summary').read_text())

    def test_plan_falls_back_for_missing_or_expired_artifacts(self):
        for state in ('missing', 'expired'):
            self.install_fixture()
            artifacts = self.api.collections['actions/runs/100/artifacts']
            if state == 'missing':
                artifacts.clear()
            else:
                artifacts[0]['expired'] = True
            with self.subTest(state=state):
                release.plan()
                self.assertEqual(self.outputs()['reuse'], 'false')
                self.assertEqual(self.outputs()['publish'], 'true')
        self.opener.return_value.open.assert_not_called()

    def test_plan_falls_back_when_an_artifact_disappears_during_download(self):
        for status in (404, 410):
            self.install_fixture()
            self.opener.return_value.open.side_effect = urllib.error.HTTPError(
                'https://api.github.com/artifact', status, 'Unavailable', {}, None)
            with self.subTest(status=status):
                release.plan()
                self.assertEqual(self.outputs()['reuse'], 'false')

    def test_plan_falls_back_when_a_historical_tested_git_object_was_removed(self):
        self.install_fixture()
        self.api.objects[f'git/commits/{SOURCE}'] = urllib.error.HTTPError(
            'https://api.github.com/commit', 404, 'Unavailable', {}, None)
        release.plan()
        self.assertEqual(self.outputs()['reuse'], 'false')

    def test_plan_does_not_hide_permission_or_server_download_failures(self):
        for status in (403, 500):
            self.install_fixture()
            self.opener.return_value.open.side_effect = urllib.error.HTTPError(
                'https://api.github.com/artifact', status, 'Failure', {}, None)
            with self.subTest(status=status), self.assertRaises(urllib.error.HTTPError):
                release.plan()

    def test_plan_falls_back_when_no_merged_pr_is_associated(self):
        self.api.collections[f'commits/{MERGED}/pulls'] = []
        release.plan()
        self.assertEqual(self.outputs()['reuse'], 'false')
        self.opener.assert_not_called()

    def test_plan_never_downloads_fork_or_unfinished_run_artifacts(self):
        for state in ('fork PR', 'fork run', 'in progress', 'failed'):
            _, run, _, _, _, pr = self.install_fixture()
            if state == 'fork PR':
                pr['head']['repo']['full_name'] = 'attacker/fork'
            elif state == 'fork run':
                run['head_repository']['full_name'] = 'attacker/fork'
            elif state == 'in progress':
                run['status'] = 'in_progress'
            else:
                run['conclusion'] = 'failure'
            with self.subTest(state=state):
                release.plan()
                self.assertEqual(self.outputs()['reuse'], 'false')
        self.opener.return_value.open.assert_not_called()

    def test_plan_does_not_bypass_newer_failed_pending_or_missing_evidence_with_older_green_run(self):
        runs_path = f'actions/workflows/build-windows.yml/runs?event=pull_request&head_sha={HEAD}'
        for state in ('failed', 'pending', 'missing artifact', 'expired artifact'):
            _, older, _, artifact, _, _ = self.install_fixture()
            newest = copy.deepcopy(older)
            newest['id'] = 101
            self.api.collections[runs_path] = [newest, older]
            if state == 'failed':
                newest['conclusion'] = 'failure'
            elif state == 'pending':
                newest.update(status='in_progress', conclusion=None)
            elif state == 'missing artifact':
                self.api.collections['actions/runs/101/artifacts'] = []
            else:
                self.api.collections['actions/runs/101/artifacts'] = [dict(artifact, expired=True)]
            with self.subTest(state=state):
                release.plan()
                self.assertEqual(self.outputs()['reuse'], 'false')
                self.assertNotIn(('pages', 'actions/runs/100/artifacts', 'artifacts'), self.api.calls)
        self.opener.return_value.open.assert_not_called()

    def test_old_artifact_namespace_is_not_reinterpreted_as_qualification(self):
        _, _, _, artifact, _, _ = self.install_fixture()
        artifact['name'] = 'qualified-windows-package'
        release.plan()
        self.assertEqual(self.outputs()['reuse'], 'false')
        self.opener.return_value.open.assert_not_called()

    def test_plan_falls_back_for_benign_tree_base_attempt_and_version_mismatches(self):
        for state in ('tree', 'base', 'attempt', 'version'):
            def mutate(values):
                if state == 'tree':
                    values[0]['sourceTree'] = values[4]['tree']['sha'] = 'f' * 40
                elif state == 'base':
                    values[5]['base']['sha'] = 'f' * 40
                elif state == 'attempt':
                    values[0]['runAttempt'] = 1
                else:
                    values[0]['version'] = 'v3.2.2.3'
            self.install_fixture(mutate=mutate)
            with self.subTest(state=state):
                release.plan()
                self.assertEqual(self.outputs()['reuse'], 'false')
                self.assertEqual(self.outputs()['artifact_id'], '')

    def test_plan_rejects_ambiguous_or_tampered_artifacts_instead_of_reusing(self):
        for state in ('ambiguous', 'digest mismatch'):
            _, _, _, artifact, _, _ = self.install_fixture()
            if state == 'ambiguous':
                self.api.collections['actions/runs/100/artifacts'].append(copy.deepcopy(artifact))
            else:
                artifact['digest'] = 'sha256:' + '0' * 64
            with self.subTest(state=state), self.assertRaises(ValueError):
                release.plan()

    def test_same_workflow_path_with_wrong_workflow_id_is_rejected(self):
        _, run, _, _, _, _ = self.install_fixture()
        run['workflow_id'] = 99
        with self.assertRaises(ValueError):
            release.plan()

    def test_component_dispatch_never_checks_or_publishes_a_release(self):
        os.environ.update(GITHUB_EVENT_NAME='workflow_dispatch', COMPONENT='postgres')
        release.plan()
        self.assertEqual(self.outputs()['publish'], 'false')
        self.assertEqual(self.outputs()['reuse'], 'false')
        self.assertEqual(self.api.calls, [])

    def test_full_dispatch_requires_a_fresh_qualification(self):
        os.environ.update(GITHUB_EVENT_NAME='workflow_dispatch', COMPONENT='all')
        release.plan()
        self.assertEqual(self.outputs()['publish'], 'true')
        self.assertEqual(self.outputs()['reuse'], 'false')
        self.assertEqual(self.api.calls, [('pages', 'releases', None)])

    def test_prepare_publish_reverifies_selected_pr_artifact(self):
        record, _, _, artifact, _, _ = self.install_fixture()
        self.select_pr_artifact(artifact)
        release.prepare_publish(VERSION, self.directory / 'publish')
        self.assertEqual(self.outputs(), {
            'source_commit': record['sourceCommit'], 'source_tree': TREE,
            'run_id': '100', 'artifact_id': str(artifact['id']),
            'artifact_digest': artifact['digest'],
        })
        self.assertEqual({path.name for path in (self.directory / 'publish').iterdir()},
                         release.filenames(VERSION))

    def test_prepare_main_allows_pending_publish_only_with_all_qualification_jobs_successful(self):
        _, run, _, _, _, _ = self.install_fixture('push')
        run.update(status='in_progress', conclusion=None)
        release.prepare_publish(VERSION, self.directory / 'publish')
        self.assertEqual(self.outputs()['run_id'], '200')
        self.assertEqual(self.outputs()['source_commit'], MERGED)

    def test_prepare_main_does_not_turn_skipped_jobs_into_success(self):
        _, run, jobs, _, _, _ = self.install_fixture('push')
        run.update(status='in_progress', conclusion=None)
        jobs[0]['conclusion'] = 'skipped'
        with self.assertRaises(ValueError):
            release.prepare_publish(VERSION, self.directory / 'publish')

    def install_publisher_retry(self):
        def mutate(values):
            values[0]['runAttempt'] = 1
            for job in values[2]:
                job['run_attempt'] = 1
        values = self.install_fixture('push', mutate=mutate)
        _, run, jobs, _, _, _ = values
        original = dict(run, run_attempt=1, status='completed', conclusion='failure')
        self.api.objects['actions/runs/200/attempts/1'] = original
        self.api.collections['actions/runs/200/attempts/1/jobs'] = jobs
        run.update(status='in_progress', conclusion=None)
        return original, jobs

    def test_retry_of_same_main_publisher_can_use_original_successful_qualification_jobs(self):
        self.install_publisher_retry()
        release.prepare_publish(VERSION, self.directory / 'publish')
        self.assertEqual(self.outputs()['source_commit'], MERGED)
        self.assertIn(('pages', 'actions/runs/200/attempts/1/jobs', 'jobs'), self.api.calls)
        self.assertNotIn(('pages', 'actions/runs/200/attempts/2/jobs', 'jobs'), self.api.calls)

    def test_publisher_retry_requires_same_original_run_head_and_completed_attempt(self):
        for field, value in (('id', 999), ('head_sha', 'f' * 40),
                             ('status', 'in_progress'), ('run_attempt', 2)):
            original, _ = self.install_publisher_retry()
            original[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.prepare_publish(VERSION, self.directory / 'publish')

    def test_publisher_retry_cannot_mix_jobs_from_different_attempts(self):
        _, jobs = self.install_publisher_retry()
        jobs[0]['run_attempt'] = 2
        with self.assertRaises(ValueError):
            release.prepare_publish(VERSION, self.directory / 'publish')

    def test_prepare_pr_does_not_use_the_main_publisher_retry_exception(self):
        _, _, _, artifact, _, _ = self.install_fixture(
            mutate=lambda values: values[0].update(runAttempt=1))
        self.select_pr_artifact(artifact)
        with self.assertRaises(release.NotReusable):
            release.prepare_publish(VERSION, self.directory / 'publish')
        self.assertNotIn(('get', 'actions/runs/100/attempts/1'), self.api.calls)

    def test_prepare_rejects_changed_selected_artifact_identity(self):
        for field, value in (('id', 301), ('digest', 'sha256:' + '0' * 64)):
            _, _, _, artifact, _, _ = self.install_fixture()
            self.select_pr_artifact(artifact)
            artifact[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.prepare_publish(VERSION, self.directory / 'publish')
        self.opener.return_value.open.assert_not_called()

    def test_prepare_rejects_disappeared_pr_association_or_artifact(self):
        for state in ('PR missing', 'artifact missing', 'artifact expired'):
            _, _, _, artifact, _, _ = self.install_fixture()
            self.select_pr_artifact(artifact)
            if state == 'PR missing':
                self.api.collections[f'commits/{MERGED}/pulls'] = []
            elif state == 'artifact missing':
                self.api.collections['actions/runs/100/artifacts'] = []
            else:
                artifact['expired'] = True
            with self.subTest(state=state), self.assertRaises(ValueError):
                release.prepare_publish(VERSION, self.directory / 'publish')
        self.opener.return_value.open.assert_not_called()

    def test_prepare_rejects_tree_change_after_planning(self):
        _, _, _, artifact, _, _ = self.install_fixture()
        self.select_pr_artifact(artifact)
        self.git.side_effect = None
        self.git.return_value = 'f' * 40
        with self.assertRaises(ValueError):
            release.prepare_publish(VERSION, self.directory / 'publish')


if __name__ == '__main__':
    unittest.main()
