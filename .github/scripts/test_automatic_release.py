"""Offline automatic-dispatch and privileged completion boundary regressions."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import urllib.error
from unittest import mock

from test_qualified_release import (
    release, OfflineTestCase, FixtureAPI,
    provenance, bundle_entries, zip_bytes, REPO, SOURCE, TREE, HEAD, BASE,
)

sys.modules['qualified_release'] = release
SPEC = importlib.util.spec_from_file_location('complete_upstream', Path(__file__).with_name('complete_upstream.py'))
completion = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(completion)

VERSION = 'v3.2.4.0'
BRANCH = 'automation/upstream-v3.2.4'
RUNS = 'actions/workflows/build-windows.yml/runs?event=workflow_dispatch&branch=main'
PROMOTIONS = f'actions/workflows/build-windows.yml/runs?event=workflow_dispatch&head_sha={SOURCE}'
MERGED = SOURCE  # Automatic ref promotion preserves the actual tested Git object.


def automatic_provenance(merged=False):
    record, run, jobs, artifact, source, pr = provenance()
    record.update(event='workflow_dispatch', automation='upstream-v1', version=VERSION)
    run.update(event='workflow_dispatch', head_sha=BASE, head_branch='main',
               display_title=f'Qualify upstream PR #17 head={HEAD} base={BASE}')
    artifact['workflow_run']['head_sha'] = BASE
    jobs.append({'name': 'plan', 'conclusion': 'success', 'run_attempt': 2})
    for job in jobs:
        job['status'] = 'completed'
    pr.update(merged=merged, state='closed' if merged else 'open', mergeable=True,
              draft=not merged, node_id='PR_fixture', user={'login': 'github-actions[bot]', 'type': 'Bot'},
              body=release.AUTOMATION_MARKER + f'\n<!-- immich-windows:automatic-head {HEAD} base {BASE} -->',
              merge_commit_sha=MERGED if merged else SOURCE)
    pr['base']['repo'] = {'full_name': REPO}
    pr['head']['ref'] = BRANCH
    return record, run, jobs, artifact, source, pr


class AutomaticTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        previous = Path.cwd()
        os.chdir(self.directory)
        self.addCleanup(os.chdir, previous)
        self.api = FixtureAPI()
        self.api.write = mock.Mock(side_effect=self.write_api)
        self.api.ready_for_review = mock.Mock(side_effect=self.ready)
        self.enterContext(mock.patch.object(release, 'API', return_value=self.api))
        self.sleep = self.enterContext(mock.patch.object(release.time, 'sleep'))
        self.git.side_effect = lambda *args: TREE if args == ('rev-parse', 'HEAD^{tree}') else self.fail(f'Unexpected git {args}')
        self.event = self.directory / 'event.json'
        os.environ['GITHUB_EVENT_PATH'] = str(self.event)
        self.inputs = {'component': 'all', 'upstream_pr': '17', 'expected_head': HEAD, 'expected_base': BASE}
        self.install()

    def install(self, merged=False):
        self.record, self.run, self.jobs, self.artifact, self.source, self.pr = automatic_provenance(merged)
        content = zip_bytes(bundle_entries(self.record))
        self.artifact.update(size_in_bytes=len(content), digest='sha256:' + release.hashlib.sha256(content).hexdigest())
        self.transport(content)
        self.pin = {'version': 'v3.2.4', 'windowsRevision': 0, 'repository': 'https://github.com/immich-app/immich.git',
                    'channel': 'stable', 'commit': 'f' * 40}
        Path('upstream.json').write_text(json.dumps(self.pin if merged else dict(self.pin, version='v3.2.2', windowsRevision=9)))
        objects = self.api.objects
        objects['actions/workflows/build-windows.yml'] = {'id': 71}
        objects['actions/runs/100'] = self.run
        objects['pulls/17'] = self.pr
        objects[f'git/commits/{SOURCE}'] = self.source
        objects['git/ref/heads/main'] = {'object': {'sha': MERGED if merged else BASE}}
        objects['branches/main'] = {'protected': False, 'commit': {'sha': MERGED if merged else BASE}}
        objects['rules/branches/main'] = []
        objects[f'contents/upstream.json?ref={HEAD}'] = {
            'encoding': 'base64', 'size': 100, 'content': release.base64.b64encode(json.dumps(self.pin).encode()).decode()}
        for commit, blob in ((BASE, '1' * 40), (HEAD, '2' * 40)):
            objects[f'git/trees/{commit}?recursive=1'] = {'truncated': False, 'tree': [
                {'path': 'upstream.json', 'mode': '100644', 'type': 'blob', 'sha': blob},
                {'path': '.github/scripts/qualified_release.py', 'mode': '100644', 'type': 'blob', 'sha': '3' * 40}]}
        self.api.collections['actions/runs/100/artifacts'] = [self.artifact]
        self.api.collections['actions/runs/100/attempts/2/jobs'] = self.jobs
        self.api.collections[RUNS] = []
        self.api.collections[PROMOTIONS] = []
        self.api.collections[f'commits/{MERGED}/pulls'] = [{'number': 17}]
        self.api.calls.clear()
        self.api.write.reset_mock()
        self.api.ready_for_review.reset_mock()
        os.environ.update(GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_SHA=BASE, COMPONENT='all')
        self.event.write_text(json.dumps({'inputs': self.inputs}))

    def write_api(self, path, data, method='POST'):
        if path == 'git/refs/heads/main':
            self.assertEqual(data, {'sha': SOURCE, 'force': False})
            self.assertEqual(method, 'PATCH')
            self.pr.update(merged=True, state='closed', merge_commit_sha=MERGED)
            self.api.objects['git/ref/heads/main']['object']['sha'] = MERGED
            return {'ref': 'refs/heads/main', 'object': {'sha': SOURCE}}
        if path == 'actions/workflows/build-windows.yml/dispatches':
            self.assertEqual(data['ref'], 'main')
            return None
        self.fail(f'Unexpected write {path}')

    def ready(self, node_id):
        self.assertEqual(node_id, 'PR_fixture')
        self.pr['draft'] = False

    def check_record(self, merged=False):
        release.validate_provenance(self.record, self.run, self.jobs, self.artifact, self.source,
                                    TREE, REPO, self.pr, allow_open_automation=not merged)

    def test_zero_versions_are_canonical_and_all_numeric_fields_are_strict(self):
        for version in ('v0.0.0.0', 'v3.2.4.0', 'v3.2.4.10'):
            self.assertEqual(len(release.filenames(version)), 4)
        for version in ('v03.2.4.0', 'v3.02.4.0', 'v3.2.04.0', 'v3.2.4.00', 'v3.2.4.-1', 'v3.2.4.0\n', 'v３.2.4.0'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.filenames(version)
        for revision in (True, '0', -1, 0.0):
            with self.subTest(revision=revision), self.assertRaises(ValueError):
                release.pin_version(dict(self.pin, windowsRevision=revision))

    def test_auto_plan_selects_exact_merge_checkout_and_never_publishes(self):
        release.plan()
        self.assertEqual(self.outputs()['checkout'], SOURCE)
        self.assertEqual(self.outputs()['version'], VERSION)
        self.assertEqual(self.outputs()['publish'], 'false')
        self.assertEqual(self.outputs()['reuse'], 'false')
        self.api.write.assert_not_called()
        self.opener.assert_not_called()

    def test_dispatch_must_match_current_main_exact_head_base_and_full_component(self):
        for changes in ({'expected_head': 'f' * 40}, {'expected_base': 'f' * 40}, {'upstream_pr': '017'},
                        {'component': 'codec'}, {'expected_head': ''}, {'qualified_run_id': '100'}):
            self.event.write_text(json.dumps({'inputs': dict(self.inputs, **changes)}))
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                release.plan()
        self.event.write_text(json.dumps({'inputs': self.inputs}))
        for ref in ('refs/heads/other', 'refs/pull/17/merge'):
            os.environ['GITHUB_REF'] = ref
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                release.plan()

    def test_bot_ownership_same_repo_state_and_canonical_branch_are_mandatory(self):
        for mutate in (
            lambda p: p['head']['repo'].update(full_name='attacker/fork'),
            lambda p: p['base']['repo'].update(full_name='attacker/fork'),
            lambda p: p['base'].update(ref='other'),
            lambda p: p['head'].update(ref='automation/upstream-v3.2.04'),
            lambda p: p['head'].update(ref='arbitrary'),
            lambda p: p['user'].update(login='someone'),
            lambda p: p.update(body=release.AUTOMATION_MARKER),
            lambda p: p.update(body=p['body'] + f'\n<!-- immich-windows:automatic-head {HEAD} base {BASE} -->'),
            lambda p: p.update(state='closed'),
            lambda p: p.update(merged=True),
        ):
            self.install()
            mutate(self.pr)
            with self.assertRaises(ValueError):
                release.plan()
        self.api.write.assert_not_called()

    def test_changed_main_conflict_and_wrong_merge_parents_fail_before_build(self):
        for state in ('main', 'conflict', 'unknown', 'parents', 'missing merge'):
            self.install()
            if state == 'main':
                self.api.objects['git/ref/heads/main']['object']['sha'] = 'f' * 40
            elif state == 'conflict':
                self.pr['mergeable'] = False
            elif state == 'unknown':
                self.pr.update(mergeable=None, merge_commit_sha=None)
            elif state == 'parents':
                self.source['parents'].reverse()
            else:
                self.pr['merge_commit_sha'] = None
            with self.subTest(state=state), self.assertRaises(ValueError):
                release.plan()

    def test_unknown_mergeability_refreshes_only_metadata_then_qualifies_once(self):
        self.pr.update(mergeable=None, merge_commit_sha=None)
        self.sleep.side_effect = lambda _: self.pr.update(mergeable=True, merge_commit_sha=SOURCE)
        release.plan()
        self.sleep.assert_called_once_with(5)
        self.assertEqual(self.outputs()['checkout'], SOURCE)
        self.api.write.assert_not_called()

    def test_exact_fresh_synthetic_merge_does_not_wait_for_nullable_mergeability(self):
        self.pr['mergeable'] = None
        release.plan()
        self.assertEqual(self.outputs()['checkout'], SOURCE)
        self.sleep.assert_not_called()

    def test_record_binds_dispatch_inputs_to_the_actual_merge_checkout(self):
        assets = self.directory / 'dist'
        assets.mkdir()
        for name, data in bundle_entries(self.record)[:-1]:
            (assets / name).write_bytes(data)
        os.environ.update(GITHUB_RUN_ID='100', QUALIFICATION_SOURCE=SOURCE)
        def checkout(*args):
            return {('status', '--porcelain', '--untracked-files=no'): '',
                    ('rev-parse', 'HEAD'): SOURCE, ('rev-parse', 'HEAD^{tree}'): TREE,
                    ('cat-file', '-p', 'HEAD'): f'tree {TREE}\nparent {BASE}\nparent {HEAD}\n'}[args]
        self.git.side_effect = checkout
        release.record_bundle(VERSION, assets)
        record = json.loads((assets / 'qualification.json').read_text())
        self.assertEqual(record['automation'], 'upstream-v1')
        self.assertEqual((record['pullRequest'], record['headCommit'], record['baseCommit']), (17, HEAD, BASE))
        self.assertEqual(record['sourceCommit'], SOURCE)
        os.environ['QUALIFICATION_SOURCE'] = 'f' * 40
        with self.assertRaises(ValueError):
            release.record_bundle(VERSION, assets)

    def test_draft_transition_uses_fixed_graphql_and_variables_and_confirms_result(self):
        self.urlopen.side_effect = None
        import io
        response = {'data': {'markPullRequestReadyForReview': {'pullRequest': {'id': 'PR_fixture', 'isDraft': False}}}}
        self.urlopen.return_value = io.BytesIO(json.dumps(response).encode())
        FixtureAPI.ready_for_review(self.api, 'PR_fixture')
        request = self.urlopen.call_args.args[0]
        self.assertEqual(request.full_url, 'https://api.github.com/graphql')
        self.assertEqual(json.loads(request.data)['variables'], {'id': 'PR_fixture'})
        self.urlopen.return_value = io.BytesIO(json.dumps({'errors': [{'message': 'denied'}]}).encode())
        with self.assertRaises(ValueError):
            FixtureAPI.ready_for_review(self.api, 'PR_fixture')

    def test_tree_allowlist_rejects_privileged_code_symlinks_modes_and_truncation(self):
        for state in ('workflow', 'script', 'symlink', 'executable', 'submodule', 'truncated', 'deleted workflow'):
            self.install()
            tree = self.api.objects[f'git/trees/{HEAD}?recursive=1']
            if state == 'truncated':
                tree['truncated'] = True
            elif state in ('symlink', 'executable', 'submodule'):
                tree['tree'][0]['mode'] = {'symlink': '120000', 'executable': '100755', 'submodule': '160000'}[state]
            elif state == 'deleted workflow':
                tree['tree'].pop()
            else:
                tree['tree'].append({'path': '.github/workflows/evil.yml' if state == 'workflow' else 'build/evil.ps1',
                                     'mode': '100644', 'type': 'blob', 'sha': '4' * 40})
            with self.subTest(state=state), self.assertRaises(ValueError):
                release.plan()

    def test_qualification_proves_dispatch_and_each_unique_terminal_job(self):
        self.check_record()
        for state in ('branch', 'event', 'run base', 'title', 'record marker', 'duplicate plan', 'skipped plan', 'pending plan'):
            self.install()
            if state == 'branch':
                self.run['head_branch'] = BRANCH
            elif state == 'event':
                self.run['event'] = 'pull_request_target'
            elif state == 'run base':
                self.run['head_sha'] = HEAD
            elif state == 'title':
                self.run['display_title'] += ' extra'
            elif state == 'record marker':
                self.record.pop('automation')
            elif state == 'duplicate plan':
                self.jobs.append(copy.deepcopy(self.jobs[-1]))
            elif state == 'skipped plan':
                self.jobs[-1]['conclusion'] = 'skipped'
            else:
                self.jobs[-1]['status'] = 'in_progress'
            with self.subTest(state=state), self.assertRaises(ValueError):
                self.check_record()

    def test_completion_verifies_merges_then_dispatches_exact_artifact_without_build(self):
        completion.complete(self.api, self.run)
        self.assertTrue(self.pr['merged'])
        self.api.ready_for_review.assert_called_once_with('PR_fixture')
        self.assertEqual(self.api.write.call_count, 2)
        dispatch = self.api.write.call_args.args[1]
        self.assertEqual(dispatch['inputs'], {'component': 'all', 'qualified_run_id': '100',
                         'qualified_artifact_id': '300', 'qualified_artifact_digest': self.artifact['digest'],
                         'expected_merge': MERGED})
        self.opener.return_value.open.assert_called_once()

    def test_bad_artifact_digest_tree_head_base_attempt_or_job_never_mutates_pr(self):
        for state in ('digest', 'tree', 'head', 'base', 'attempt', 'skipped', 'fork', 'failed', 'source parents', 'missing artifact'):
            self.install()
            event = copy.deepcopy(self.run)
            if state == 'digest':
                self.artifact['digest'] = 'sha256:' + '0' * 64
            elif state == 'tree':
                self.source['tree']['sha'] = 'f' * 40
            elif state == 'head':
                self.pr['head']['sha'] = 'f' * 40
            elif state == 'base':
                self.api.objects['git/ref/heads/main']['object']['sha'] = 'f' * 40
            elif state == 'attempt':
                event['run_attempt'] = 1
            elif state == 'skipped':
                self.jobs[0]['conclusion'] = 'skipped'
            elif state == 'fork':
                self.run['head_repository']['full_name'] = 'attacker/fork'
            elif state == 'failed':
                self.run['conclusion'] = 'failure'
            elif state == 'source parents':
                self.source['parents'].reverse()
            else:
                self.api.collections['actions/runs/100/artifacts'].clear()
            with self.subTest(state=state), self.assertRaises(ValueError):
                completion.complete(self.api, event)
            self.api.write.assert_not_called()
            self.api.ready_for_review.assert_not_called()

    def test_main_race_during_draft_transition_refuses_merge(self):
        def changed(node):
            self.ready(node)
            self.api.objects['git/ref/heads/main']['object']['sha'] = 'f' * 40
        self.api.ready_for_review.side_effect = changed
        with self.assertRaises(ValueError):
            completion.complete(self.api, self.run)
        self.api.write.assert_not_called()

    def test_merge_tree_parent_or_main_race_refuses_publication(self):
        for state in ('tree', 'parent', 'main'):
            self.install()
            def race(path, data, method='POST'):
                result = self.write_api(path, data, method)
                if state == 'tree':
                    self.api.objects[f'git/commits/{MERGED}']['tree']['sha'] = 'f' * 40
                elif state == 'parent':
                    self.api.objects[f'git/commits/{MERGED}']['parents'] = [{'sha': 'f' * 40}]
                else:
                    self.api.objects['git/ref/heads/main']['object']['sha'] = 'f' * 40
                return result
            self.api.write.side_effect = race
            with self.subTest(state=state), self.assertRaises(ValueError):
                completion.complete(self.api, self.run)
            self.assertEqual(self.api.write.call_count, 1)

    def test_divergent_main_race_is_rejected_without_landing_any_new_main_tree(self):
        def conflict(path, data, method='POST'):
            self.assertEqual(path, 'git/refs/heads/main')
            self.assertEqual(data, {'sha': SOURCE, 'force': False})
            self.api.objects['git/ref/heads/main']['object']['sha'] = 'f' * 40
            raise urllib.error.HTTPError('fixture', 422, 'Not a fast forward', {}, None)
        self.api.write.side_effect = conflict
        with self.assertRaises(urllib.error.HTTPError):
            completion.complete(self.api, self.run)
        self.assertEqual(self.api.objects['git/ref/heads/main']['object']['sha'], 'f' * 40)
        self.assertFalse(self.pr['merged'])
        self.assertEqual(self.api.write.call_count, 1)

    def test_future_branch_protection_or_rules_block_ref_promotion(self):
        for state in ('protected', 'rules'):
            self.install()
            if state == 'protected':
                self.api.objects['branches/main']['protected'] = True
            else:
                self.api.objects['rules/branches/main'] = [{'type': 'required_signatures'}]
            with self.subTest(state=state), self.assertRaises(ValueError):
                completion.complete(self.api, self.run)
            self.api.ready_for_review.assert_not_called()
            self.api.write.assert_not_called()

    def test_indirect_merge_metadata_wait_never_repeats_the_ref_write(self):
        def pending(path, data, method='POST'):
            response = self.write_api(path, data, method)
            if path == 'git/refs/heads/main':
                self.pr.update(merged=False, state='open')
            return response
        self.api.write.side_effect = pending
        self.sleep.side_effect = lambda _: self.pr.update(merged=True, state='closed', base=dict(self.pr['base'], sha=SOURCE))
        completion.complete(self.api, self.run)
        self.sleep.assert_called_once_with(5)
        self.assertEqual(sum(c.args[0] == 'git/refs/heads/main' for c in self.api.write.call_args_list), 1)
        self.assertEqual(self.api.write.call_count, 2)

    def test_indirect_merge_timeout_and_changed_pr_head_suppress_publication(self):
        for state in ('pending', 'head moved'):
            self.install()
            def changed(path, data, method='POST'):
                response = self.write_api(path, data, method)
                self.pr.update(merged=False, state='open')
                if state == 'head moved':
                    self.pr['head']['sha'] = 'f' * 40
                return response
            self.api.write.side_effect = changed
            with self.subTest(state=state), self.assertRaises(ValueError):
                completion.complete(self.api, self.run)
            self.assertEqual(self.api.write.call_count, 1)

    def test_indirect_merged_base_metadata_may_equal_only_original_or_exact_promoted_commit(self):
        self.install(merged=True)
        self.pr['base']['sha'] = SOURCE
        completion.complete(self.api, self.run)
        self.api.write.assert_called_once()
        self.api.collections[RUNS] = [self.run]
        selected = release.select_qualified_pr(self.api, SOURCE, VERSION, target_tree=TREE)
        self.assertEqual(selected[1]['id'], 100)
        self.pr['base']['sha'] = 'f' * 40
        with self.assertRaises(ValueError):
            completion.complete(self.api, self.run)

    def test_completion_rerun_recovers_merged_pr_but_never_repeats_existing_dispatch(self):
        self.install(merged=True)
        completion.complete(self.api, self.run)
        self.api.ready_for_review.assert_not_called()
        self.api.write.assert_called_once()
        self.api.write.reset_mock()
        self.api.collections[PROMOTIONS] = [{'display_title': f'Promote qualified run 100 at {MERGED}', 'head_sha': MERGED, 'id': 101}]
        completion.complete(self.api, self.run)
        self.api.write.assert_not_called()

    def test_non_automatic_main_dispatch_cannot_trigger_completion(self):
        self.run['display_title'] = 'Windows qualification'
        completion.complete(self.api, self.run)
        self.api.write.assert_not_called()
        self.opener.assert_not_called()

    def promotion_inputs(self):
        return {'component': 'all', 'qualified_run_id': '100', 'qualified_artifact_id': '300',
                'qualified_artifact_digest': self.artifact['digest'], 'expected_merge': MERGED}

    def test_promotion_selects_exact_qualification_and_never_falls_back_to_build(self):
        self.install(merged=True)
        os.environ['GITHUB_SHA'] = MERGED
        self.event.write_text(json.dumps({'inputs': self.promotion_inputs()}))
        release.plan()
        self.assertEqual(self.outputs()['reuse'], 'true')
        self.assertEqual(self.outputs()['publish'], 'true')
        self.assertEqual(self.outputs()['artifact_id'], '300')
        for state in ('missing', 'digest', 'expired', 'stale main'):
            self.install(merged=True)
            os.environ['GITHUB_SHA'] = MERGED
            self.event.write_text(json.dumps({'inputs': self.promotion_inputs()}))
            if state == 'missing':
                self.api.collections['actions/runs/100/artifacts'].clear()
            elif state == 'digest':
                self.artifact['digest'] = 'sha256:' + '0' * 64
            elif state == 'expired':
                self.artifact['expired'] = True
            else:
                self.api.objects['git/ref/heads/main']['object']['sha'] = 'f' * 40
            with self.subTest(state=state), self.assertRaises(ValueError):
                release.plan()

    def test_publisher_revalidates_automatic_record_against_main_tree(self):
        self.install(merged=True)
        os.environ.update(GITHUB_SHA=MERGED, QUALIFIED_RUN_ID='100', QUALIFIED_ARTIFACT_ID='300',
                          QUALIFIED_ARTIFACT_DIGEST=self.artifact['digest'])
        release.prepare_publish(VERSION, self.directory / 'published')
        self.assertEqual(self.outputs()['source_tree'], TREE)
        self.assertEqual(self.outputs()['source_commit'], SOURCE)

    def test_main_and_native_selection_reuse_automatic_qualification(self):
        self.install(merged=True)
        self.api.collections[RUNS] = [self.run]
        selected = release.select_qualified_pr(self.api, MERGED, VERSION, target_tree=TREE)
        self.assertEqual(selected[1]['id'], 100)

    def recovery(self, merged=True):
        self.install(merged=merged)
        self.enterContext(mock.patch.object(completion, 'API', return_value=self.api))
        self.api.objects[f'releases/tags/{VERSION}'] = urllib.error.HTTPError('fixture', 404, 'Absent', {}, None)
        self.api.collections[f'actions/workflows/complete-upstream.yml/runs?event=workflow_run&head_sha={BASE}'] = []
        self.api.collections[f'actions/workflows/build-windows.yml/runs?event=workflow_dispatch&head_sha={BASE}'] = [self.run]

    def test_daily_recovery_retries_failed_exact_promotion_without_qualification(self):
        self.recovery()
        self.api.collections[PROMOTIONS] = [{'display_title': f'Promote qualified run 100 at {SOURCE}',
                                      'head_sha': SOURCE, 'id': 101, 'status': 'completed', 'conclusion': 'failure'}]
        self.assertTrue(completion.recover_publication(SOURCE, self.pin))
        self.api.write.assert_called_once()
        self.assertEqual(self.api.write.call_args.args[1]['inputs']['qualified_run_id'], '100')
        self.assertNotIn('upstream_pr', self.api.write.call_args.args[1]['inputs'])

    def test_daily_recovery_skips_pending_or_successful_promotion(self):
        self.recovery()
        for status, conclusion in [('in_progress', None), ('queued', None), ('completed', 'success')]:
            self.api.collections[PROMOTIONS] = [{'display_title': f'Promote qualified run 100 at {SOURCE}',
                                          'head_sha': SOURCE, 'id': 101, 'status': status, 'conclusion': conclusion}]
            with self.subTest(status=status, conclusion=conclusion):
                self.assertFalse(completion.recover_publication(SOURCE, self.pin))
        self.api.write.assert_not_called()

    def test_daily_recovery_never_bypasses_newer_failed_or_pending_qualification(self):
        self.recovery()
        for status, conclusion in [('in_progress', None), ('completed', 'failure')]:
            newest = dict(self.run, id=101, status=status, conclusion=conclusion)
            self.api.collections[f'actions/workflows/build-windows.yml/runs?event=workflow_dispatch&head_sha={BASE}'] = [newest, self.run]
            with self.subTest(status=status):
                self.assertFalse(completion.recover_publication(SOURCE, self.pin))
        self.api.write.assert_not_called()
        self.opener.assert_not_called()

    def test_daily_recovery_current_published_version_is_lightweight_noop(self):
        self.recovery()
        self.api.objects[f'releases/tags/{VERSION}'] = {'tag_name': VERSION, 'draft': False}
        self.assertFalse(completion.recover_publication(SOURCE, self.pin))
        self.api.write.assert_not_called()
        self.opener.assert_not_called()

    def test_daily_recovery_does_not_scan_or_rebuild_nonautomatic_main(self):
        self.recovery()
        self.pr['head']['ref'] = 'manual-feature'
        self.assertFalse(completion.recover_publication(SOURCE, self.pin))
        self.api.write.assert_not_called()
        self.opener.assert_not_called()

    def test_daily_green_qualification_continues_failed_completion_once(self):
        self.recovery(merged=False)
        self.api.collections[f'actions/workflows/complete-upstream.yml/runs?event=workflow_run&head_sha={BASE}'] = [
            {'display_title': 'Complete qualified run 100', 'status': 'completed', 'conclusion': 'failure'}]
        self.assertTrue(completion.recover_completion(100))
        self.assertEqual(self.api.write.call_count, 2)
        self.assertEqual(self.api.write.call_args_list[0].args[0], 'git/refs/heads/main')
        self.assertEqual(self.api.write.call_args_list[1].args[1]['inputs']['qualified_run_id'], '100')

    def test_daily_green_qualification_does_not_repeat_pending_completion(self):
        self.recovery(merged=False)
        self.api.collections[f'actions/workflows/complete-upstream.yml/runs?event=workflow_run&head_sha={BASE}'] = [
            {'display_title': 'Complete qualified run 100', 'status': 'in_progress', 'conclusion': None}]
        self.assertFalse(completion.recover_completion(100))
        self.api.write.assert_not_called()
        self.opener.assert_not_called()

    def test_recovery_refuses_unknown_continuation_after_bounded_identity_page(self):
        self.recovery(merged=False)
        self.api.collections[f'actions/workflows/complete-upstream.yml/runs?event=workflow_run&head_sha={BASE}'] = [
            {'display_title': f'other {i}'} for i in range(101)]
        with self.assertRaisesRegex(ValueError, 'bounded lookup'):
            completion.recover_completion(100)
        self.api.write.assert_not_called()

    def test_recovery_refuses_unknown_promotion_after_bounded_exact_main_page(self):
        self.recovery()
        self.api.collections[PROMOTIONS] = [{'display_title': f'other {i}'} for i in range(101)]
        with self.assertRaisesRegex(ValueError, 'bounded lookup'):
            completion.recover_publication(SOURCE, self.pin)
        self.api.write.assert_not_called()

    def test_privileged_workflow_checks_out_only_default_main_and_never_artifact_code(self):
        workflows = Path(__file__).parents[1] / 'workflows'
        text = (workflows / 'complete-upstream.yml').read_text()
        self.assertIn('ref: ${{ github.sha }}', text)
        self.assertNotIn('ref: ${{ github.event.workflow_run.head_sha }}', text)
        self.assertNotIn('download-artifact', text)
        self.assertIn('persist-credentials: false', text)
        build = (workflows / 'build-windows.yml').read_text()
        self.assertIn("github.event.pull_request.user.login != 'github-actions[bot]'", build)
        self.assertIn('ref: ${{ needs.plan.outputs.checkout || github.sha }}', build)
