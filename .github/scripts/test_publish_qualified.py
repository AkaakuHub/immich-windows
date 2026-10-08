"""Offline evidence-bound draft and incomplete upload recovery tests."""
import copy
import io
import json
import os
from pathlib import Path
from unittest import mock
import urllib.error

from test_qualified_release import release, OfflineTestCase, FixtureAPI, bundle_entries, provenance, MERGED
import publish_qualified as publisher
UPLOAD = publisher.upload


class PublicationTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.api = FixtureAPI()
        entries = bundle_entries()
        self.record = json.loads(entries[-1][1])
        self.artifact = provenance()[3]
        for name, content in entries[:-1]:
            (self.directory / name).write_bytes(content)
        self.version = self.record['version']
        self.api.objects['git/ref/heads/main'] = {'object': {'sha': MERGED}}
        self.api.objects[f'git/ref/tags/{self.version}'] = urllib.error.HTTPError('fixture', 404, 'Absent', {}, None)
        self.api.collections['releases'] = []
        self.api.objects[f'releases/tags/{self.version}'] = urllib.error.HTTPError('fixture', 404, 'Absent', {}, None)
        self.api.collections['releases/77/assets'] = []
        self.api.write = mock.Mock(side_effect=self.write_api)
        self.upload = self.enterContext(mock.patch.object(publisher, 'upload', side_effect=self.upload_api))

    def draft(self):
        value = {'id': 77, 'tag_name': self.version, 'name': self.version, 'target_commitish': MERGED,
                 'body': publisher.notes(self.record, self.artifact, MERGED), 'draft': True, 'prerelease': False,
                 'author': {'login': 'github-actions[bot]'}}
        self.api.collections['releases'] = [value]
        self.api.objects['releases/77'] = value
        return value

    def asset(self, name):
        return {'id': sorted(self.record['assets']).index(name) + 100, 'name': name, 'state': 'uploaded',
                'size': (self.directory / name).stat().st_size, 'digest': 'sha256:' + self.record['assets'][name],
                'label': publisher.asset_label(self.record, self.artifact, name),
                'uploader': {'login': 'github-actions[bot]'}}

    def upload_api(self, api, release_id, path, label):
        self.assertIs(api, self.api)
        self.assertEqual(release_id, 77)
        self.assertEqual(label, publisher.asset_label(self.record, self.artifact, path.name))
        self.assertFalse(any(a['name'] == path.name for a in self.api.collections['releases/77/assets']))
        asset = self.asset(path.name)
        self.api.collections['releases/77/assets'].append(asset)
        return copy.deepcopy(asset)

    def write_api(self, path, data, method='POST'):
        if path == 'releases':
            self.assertEqual(method, 'POST')
            value = self.draft()
            for key, expected in data.items():
                self.assertEqual(value[key], expected)
            return copy.deepcopy(value)
        if path == 'releases/77':
            self.assertEqual(method, 'PATCH')
            if not self.api.objects[path]['draft']:
                self.assertEqual(data, {'body': publisher.notes(self.record, self.artifact, MERGED)})
                self.api.objects[path]['body'] = data['body']
                return copy.deepcopy(self.api.objects[path])
            self.assertEqual(data, {'body': publisher.notes(self.record, self.artifact, MERGED), 'draft': False, 'make_latest': 'true'})
            self.api.objects[path].update(body=data['body'], draft=False)
            self.api.objects[f'git/ref/tags/{self.version}'] = {'object': {'type': 'commit', 'sha': MERGED}}
            return copy.deepcopy(self.api.objects[path])
        if path.startswith('releases/assets/'):
            asset_id = int(path.rsplit('/', 1)[-1])
            assets = self.api.collections['releases/77/assets']
            if method == 'PATCH':
                self.assertEqual(data, {'label': ''})
                self.assertEqual(len(assets), 4)
                self.assertTrue(all(a['state'] == 'uploaded' for a in assets))
                asset = next(a for a in assets if a['id'] == asset_id)
                asset['label'] = ''
                return copy.deepcopy(asset)
            self.assertEqual(method, 'DELETE')
            self.assertIsNone(data)
            assets[:] = [a for a in assets if a['id'] != asset_id]
            return None
        self.fail(f'Unexpected write {path}')

    def publish(self):
        return publisher.publish(self.api, self.record, self.artifact, self.directory, MERGED)

    def metadata_fixture(self):
        value = self.draft()
        value.update(draft=False, body=publisher.notes(self.record, self.artifact, MERGED, legacy=True))
        self.api.objects[f'releases/tags/{self.version}'] = value
        self.api.objects[f'git/ref/tags/{self.version}'] = {'object': {'type': 'commit', 'sha': MERGED}}
        _, run, jobs, _, source, _ = provenance()
        self.api.objects[f"git/commits/{source['sha']}"] = source
        self.api.objects[f'git/commits/{MERGED}'] = dict(source, sha=MERGED)
        self.api.objects[f"actions/runs/{run['id']}"] = run
        self.api.objects[f"actions/artifacts/{self.artifact['id']}"] = self.artifact
        self.api.collections[f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"] = jobs
        self.api.collections['releases/77/assets'] = [self.asset(name) for name in self.record['assets']]
        os.environ.update(QUALIFIED_RUN_ID=str(run['id']), QUALIFIED_ARTIFACT_ID=str(self.artifact['id']),
                          QUALIFIED_ARTIFACT_DIGEST=self.artifact['digest'])
        return value

    def test_existing_main_plan_selects_metadata_only_without_artifact_download(self):
        self.metadata_fixture()
        with mock.patch.object(release, 'API', return_value=self.api), mock.patch.object(release, 'release_policy', return_value=False), \
                mock.patch.object(release.Path, 'read_text', return_value=json.dumps({'version': 'v3.2.2', 'windowsRevision': 4})), \
                mock.patch.object(release, 'output') as output:
            release.plan()
        values = output.call_args.args[0]
        self.assertTrue(values['reuse'] and values['publish'] and values['metadata_only'])
        self.assertEqual(values['artifact_id'], self.artifact['id'])
        self.upload.assert_not_called()
        self.api.write.assert_not_called()
        self.opener.assert_not_called()

    def test_published_metadata_changes_exactly_labels_and_body_then_is_a_noop(self):
        value = self.metadata_fixture()
        original = copy.deepcopy(self.api.collections['releases/77/assets'])
        old_hidden = value['body'].split('<!--')[1]
        with mock.patch.object(publisher, 'release_policy', return_value=False):
            publisher.refresh_published_metadata(self.api, self.version, MERGED)
            self.assertEqual(self.api.write.call_count, 5)
            self.assertEqual(value['body'].split('<!--')[1], old_hidden)
            for before, after in zip(original, self.api.collections['releases/77/assets']):
                self.assertEqual(after, dict(before, label=''))
            self.api.write.reset_mock()
            publisher.refresh_published_metadata(self.api, self.version, MERGED)
            self.api.write.assert_not_called()
        self.upload.assert_not_called()
        self.opener.assert_not_called()

    def test_metadata_repair_refuses_changed_payload_or_selected_evidence_before_write(self):
        for changed in ('payload', 'artifact', 'tag', 'asset', 'body', 'run'):
            value = self.metadata_fixture()
            if changed == 'artifact': os.environ['QUALIFIED_ARTIFACT_ID'] = '999'
            if changed == 'tag': self.api.objects[f'git/ref/tags/{self.version}']['object']['sha'] = 'f' * 40
            if changed == 'asset': self.api.collections['releases/77/assets'][0]['digest'] = 'sha256:' + 'f' * 64
            if changed == 'body': value['body'] += 'changed'
            if changed == 'run': self.api.objects['actions/runs/100']['conclusion'] = 'failure'
            with self.subTest(changed=changed), mock.patch.object(publisher, 'release_policy', return_value=changed == 'payload'), self.assertRaises(ValueError):
                publisher.refresh_published_metadata(self.api, self.version, MERGED)
            self.api.write.assert_not_called()
        self.upload.assert_not_called()
        self.opener.assert_not_called()

    def test_upload_streams_exact_bytes_to_fixed_host_with_length_and_owned_label(self):
        name = sorted(self.record['assets'])[0]
        path = self.directory / name
        label = publisher.asset_label(self.record, self.artifact, name)
        self.opener.side_effect = None
        def accept(request, timeout):
            self.assertTrue(request.full_url.startswith(f'https://uploads.github.com/repos/{self.api.repo}/releases/77/assets?'))
            self.assertEqual(request.get_header('Content-length'), str(path.stat().st_size))
            self.assertEqual(request.get_header('Authorization'), 'Bearer offline-test-token')
            self.assertEqual(b''.join(request.data), path.read_bytes())
            self.assertIn('label=', request.full_url)
            return io.BytesIO(b'{"id":100}')
        self.opener.return_value.open.side_effect = accept
        self.assertEqual(UPLOAD(self.api, 77, path, label), {'id': 100})

    def test_missing_draft_outside_one_recent_page_fails_closed(self):
        self.api.collections['releases'] = [{'tag_name': f'v1.0.0.{i}'} for i in range(101)]
        with self.assertRaisesRegex(ValueError, 'bounded lookup'):
            self.publish()
        self.upload.assert_not_called()
        self.api.write.assert_not_called()

    def test_new_release_publishes_only_after_all_four_assets_verify(self):
        self.publish()
        self.assertEqual(self.upload.call_count, 4)
        self.assertFalse(self.api.objects['releases/77']['draft'])
        self.assertEqual(self.api.write.call_args_list[-1], mock.call('releases/77', {'body': publisher.notes(self.record, self.artifact, MERGED), 'draft': False, 'make_latest': 'true'}, method='PATCH'))
        self.assertTrue(all(a['label'] == '' for a in self.api.collections['releases/77/assets']))

    def test_owned_partial_draft_uploads_only_missing_assets(self):
        self.draft()
        existing = sorted(self.record['assets'])[:2]
        self.api.collections['releases/77/assets'] = [self.asset(n) for n in existing]
        self.publish()
        self.assertEqual({c.args[2].name for c in self.upload.call_args_list}, set(self.record['assets']) - set(existing))
        self.assertEqual(self.api.write.call_count, 5)

    def test_japanese_notes_preserve_the_exact_hidden_provenance(self):
        body = publisher.notes(self.record, self.artifact, MERGED)
        legacy = publisher.notes(self.record, self.artifact, MERGED, legacy=True)
        self.assertEqual(body[body.index('<!--'):], legacy[legacy.index('<!--'):])
        visible = body[:body.index('<!--')]
        self.assertIn('通常の導入・更新', visible)
        self.assertIn('`Install.cmd`', visible)
        self.assertIn(f'/blob/{MERGED}/docs/install.md', visible)
        for name in publisher.filenames(self.record['version']):
            self.assertIn(name, visible)
        self.assertIn('`dependency-*`', visible)
        self.assertNotIn('Artifact:', visible)
        self.assertNotIn('Actual build commit:', visible)
        for version in ('v3.2.4.0', 'v3.2.5.0'):
            version_body = publisher.notes(dict(self.record, version=version), self.artifact, MERGED)
            self.assertEqual('保存済みの古いものではなく' in version_body, version == 'v3.2.4.0')

    def test_legacy_owned_draft_resumes_with_new_notes_and_normal_filenames(self):
        self.draft()['body'] = publisher.notes(self.record, self.artifact, MERGED, legacy=True)
        self.assertTrue(release.release_policy(self.api, self.version, resume=(self.record, self.artifact, MERGED)))
        self.publish()
        self.assertEqual(self.api.objects['releases/77']['body'], publisher.notes(self.record, self.artifact, MERGED))
        self.assertTrue(all(a['label'] == '' for a in self.api.collections['releases/77/assets']))

    def test_changed_hidden_provenance_is_not_accepted_in_either_notes_format(self):
        for legacy in (False, True):
            body = publisher.notes(self.record, self.artifact, MERGED, legacy=legacy)
            visible, marker = body.split('<!--', 1)
            self.draft()['body'] = visible + '<!--' + marker.replace('"runId":100', '"runId":999')
            with self.subTest(legacy=legacy), self.assertRaises(ValueError):
                self.publish()
        self.upload.assert_not_called()
        self.api.write.assert_not_called()

    def test_partial_label_update_resumes_without_reuploading_or_repeating_cleared_labels(self):
        self.draft()
        first = True
        def uncertain(path, data, method='POST'):
            nonlocal first
            result = self.write_api(path, data, method)
            if path.startswith('releases/assets/') and method == 'PATCH' and first:
                first = False
                raise urllib.error.URLError('response lost after label update')
            return result
        self.api.write.side_effect = uncertain
        with self.assertRaises(urllib.error.URLError):
            self.publish()
        self.assertTrue(self.api.objects['releases/77']['draft'])
        self.upload.reset_mock()
        self.api.write.reset_mock(side_effect=True)
        self.api.write.side_effect = self.write_api
        self.publish()
        self.upload.assert_not_called()
        self.assertEqual(self.api.write.call_count, 4)  # Three remaining labels and publication.

    def test_label_update_must_preserve_asset_identity_before_publication(self):
        for key, value in [('name', 'renamed.zip'), ('size', 0), ('digest', 'sha256:' + 'f' * 64),
                           ('state', 'starter'), ('id', 999), ('label', 'still visible')]:
            self.draft()
            self.api.collections['releases/77/assets'] = [self.asset(n) for n in self.record['assets']]
            def changed(path, data, method='POST'):
                result = self.write_api(path, data, method)
                result[key] = value
                return result
            self.api.write.side_effect = changed
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'qualified identity'):
                self.publish()
            self.assertTrue(self.api.objects['releases/77']['draft'])

    def test_unowned_or_mismatched_draft_fails_before_any_upload_or_write(self):
        for field, value in [('body', 'foreign'), ('target_commitish', 'f' * 40), ('name', 'other'),
                             ('prerelease', True), ('author', {'login': 'someone'})]:
            draft = self.draft()
            draft[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.publish()
        self.upload.assert_not_called()
        self.api.write.assert_not_called()

    def test_all_existing_assets_validate_before_any_missing_upload(self):
        self.draft()
        name = sorted(self.record['assets'])[0]
        for field, value in [('digest', 'sha256:' + 'f' * 64), ('size', 0), ('state', 'unknown'), ('name', 'foreign.exe')]:
            asset = self.asset(name)
            asset[field] = value
            self.api.collections['releases/77/assets'] = [asset]
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.publish()
        self.upload.assert_not_called()
        self.api.write.assert_not_called()

    def test_wrong_existing_tag_is_never_moved_or_reused(self):
        self.draft()
        self.api.objects[f'git/ref/tags/{self.version}'] = {'object': {'type': 'commit', 'sha': 'f' * 40}}
        with self.assertRaises(ValueError):
            self.publish()
        self.upload.assert_not_called()
        self.api.write.assert_not_called()

    def test_owned_empty_starter_from_502_is_removed_then_uploaded_once(self):
        self.draft()
        name = sorted(self.record['assets'])[0]
        starter = dict(self.asset(name), state='starter', size=0, digest=None)
        self.api.collections['releases/77/assets'] = [starter]
        self.publish()
        self.assertEqual(self.api.write.call_args_list[0], mock.call(f"releases/assets/{starter['id']}", None, method='DELETE'))
        self.assertEqual(self.upload.call_count, 4)

    def test_foreign_nonempty_or_unlabelled_starter_is_never_deleted(self):
        self.draft()
        name = sorted(self.record['assets'])[0]
        for field, value in [('label', ''), ('size', 1), ('digest', 'sha256:' + 'f' * 64),
                             ('uploader', {'login': 'someone'})]:
            asset = dict(self.asset(name), state='starter', size=0, digest=None)
            asset[field] = value
            self.api.collections['releases/77/assets'] = [asset]
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.publish()
        self.upload.assert_not_called()
        self.api.write.assert_not_called()

    def test_uncertain_accepted_upload_is_read_once_and_never_repeated(self):
        self.draft()
        first = True
        def uncertain(*args):
            nonlocal first
            result = self.upload_api(*args)
            if first:
                first = False
                raise urllib.error.URLError('response lost after acceptance')
            return result
        self.upload.side_effect = uncertain
        self.publish()
        self.assertEqual(self.upload.call_count, 4)
        self.assertEqual(len(self.api.collections['releases/77/assets']), 4)

    def test_failed_upload_with_starter_is_left_then_resumed_on_next_attempt(self):
        self.draft()
        def failed(api, release_id, path, label):
            self.api.collections['releases/77/assets'].append(dict(self.asset(path.name), state='starter', size=0, digest=None))
            raise urllib.error.HTTPError('fixture', 502, 'Upload incomplete', {}, None)
        self.upload.side_effect = failed
        with self.assertRaises(urllib.error.HTTPError):
            self.publish()
        self.assertEqual(self.upload.call_count, 1)
        self.assertTrue(self.api.objects['releases/77']['draft'])
        self.api.write.assert_not_called()
        self.upload.reset_mock(side_effect=True)
        self.upload.side_effect = self.upload_api
        self.publish()
        self.assertEqual(self.upload.call_count, 4)
        self.assertFalse(self.api.objects['releases/77']['draft'])

    def test_failed_final_publish_resumes_without_reuploading_assets(self):
        self.draft()
        def failed_publish(path, data, method='POST'):
            if path == 'releases/77':
                raise urllib.error.HTTPError('fixture', 500, 'Transient publish failure', {}, None)
            return self.write_api(path, data, method)
        self.api.write.side_effect = failed_publish
        with self.assertRaises(urllib.error.HTTPError):
            self.publish()
        self.assertEqual(self.upload.call_count, 4)
        self.api.write.side_effect = self.write_api
        self.upload.reset_mock()
        self.publish()
        self.upload.assert_not_called()
        self.assertFalse(self.api.objects['releases/77']['draft'])

    def test_exact_published_release_is_a_noop_and_incomplete_one_is_immutable(self):
        self.publish()
        self.api.write.reset_mock()
        self.upload.reset_mock()
        self.publish()
        self.api.write.assert_not_called()
        self.upload.assert_not_called()
        self.api.collections['releases/77/assets'].pop()
        with self.assertRaises(ValueError):
            self.publish()
        self.api.write.assert_not_called()
        self.upload.assert_not_called()

    def test_policy_resumes_only_a_bound_draft_for_explicit_promotion(self):
        self.draft()
        self.assertTrue(release.release_policy(self.api, self.version, resume=(self.record, self.artifact, MERGED)))
        with self.assertRaises(ValueError):
            release.release_policy(self.api, self.version)
        self.api.objects['releases/77']['body'] = 'unowned'
        with self.assertRaises(ValueError):
            release.release_policy(self.api, self.version, resume=(self.record, self.artifact, MERGED))
