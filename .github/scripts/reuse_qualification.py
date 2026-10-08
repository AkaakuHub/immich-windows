"""Reuse immutable Windows qualification for unchanged product/test inputs.

This is a read-only CI check shortcut, never a release promotion path. The old
package, source commit and qualification remain unchanged. Publishing still
requires qualified_release.py's exact merged-tree and mandatory-job checks.
"""
import base64
import copy
from datetime import datetime
from itertools import islice
import json
import os
import re
from pathlib import Path
import tempfile
import urllib.error
import urllib.parse

from qualified_release import (
    API, ARTIFACT, DIGEST, REQUIRED_JOBS, SHA, WORKFLOW, NotReusable,
    artifacts_for, package_filenames, git, output, pin_version, require, sha256,
    summary, validate_bundle, validate_provenance, WINDOWS_VERSION,
)

# Exact unshipped orchestration files. Unknown files, all product/build/test
# files and shipped documentation remain inputs. These Python tools are tested
# afresh on every run, including promotions and read-only qualification reuse.
RELEASE_TOOLS = frozenset({
    '.github/scripts/' + name for name in (
        'check_upstream.py', 'complete_upstream.py', 'publish_qualified.py',
        'qualified_release.py', 'reuse_qualification.py', 'upstream_pins.py',
        'test_check_upstream.py', 'test_automatic_release.py',
        'test_publish_qualified.py', 'test_qualified_release.py',
        'test_reuse_qualification.py', 'test_upstream_pins.py',
        'test_assemble_cache.py', 'test_ci_install_optimization.py',
    )
}) | {'docs/development.md'}

CACHE_ACTION = 'actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9'
UPLOAD_ACTION = 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
PYTHON_TEST = "python -m unittest discover -s .github/scripts -p 'test_*.py' -v"


def workflow_inputs(text):
    """Compare execution semantics, with small explicit transport exceptions.

    No generic YAML text stripping or workflow ignore. The safe loader rejects
    duplicate keys, aliases and merge keys. Unknown fields/steps stay inputs.
    """
    import yaml

    class UniqueLoader(yaml.BaseLoader):
        # Keep scalar spellings intact: Python bool/int equality and YAML 1.1
        # yes/no/on resolution must not erase a changed execution input.
        def construct_object(self, node, deep=False):
            require(node.tag in ('tag:yaml.org,2002:str', 'tag:yaml.org,2002:map', 'tag:yaml.org,2002:seq'),
                    'Explicit workflow types are not reusable')
            return super().construct_object(node, deep=deep)

        def compose_node(self, parent, index):
            require(not self.check_event(yaml.AliasEvent), 'Workflow aliases are not reusable')
            return super().compose_node(parent, index)

        def construct_mapping(self, node, deep=False):
            keys = [self.construct_object(key, deep=deep) for key, _ in node.value]
            require(len(keys) == len(set(keys)), 'Duplicate workflow mapping key')
            require('<<' not in keys, 'Workflow merge keys are not reusable')
            return super().construct_mapping(node, deep=deep)

    workflow = yaml.load(text, Loader=UniqueLoader)
    require(isinstance(workflow, dict) and isinstance(workflow.get('jobs'), dict),
            'Invalid qualification workflow')
    workflow = copy.deepcopy(workflow)
    # Recognize only the complete, fixed always-run CI test lane and its exact
    # migration from validate. Any extra step/output/permission remains an input.
    parser_step = {'name': 'Install strict workflow parser',
                   'run': 'python -m pip install --disable-pip-version-check PyYAML==6.0.3'}
    checkout = {'uses': 'actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09',
                'with': {'ref': '${{ needs.plan.outputs.checkout || github.sha }}',
                         'persist-credentials': 'false'}}
    ci_tools = {'needs': 'plan', 'if': "${{ !cancelled() && needs.plan.result == 'success' }}",
                'runs-on': 'ubuntu-24.04', 'steps': [checkout, parser_step,
                {'name': 'Test current CI scripts and workflow contracts', 'run': PYTHON_TEST}]}
    legacy_test = {'name': 'Test artifact promotion and rejection policies', 'run': PYTHON_TEST}
    legacy = workflow['jobs'].get('validate', {})
    require('ci-tools' in workflow['jobs'] or legacy_test in legacy.get('steps', []),
            'Missing current CI policy test lane')
    if workflow['jobs'].get('ci-tools') == ci_tools:
        del workflow['jobs']['ci-tools']
    plan = workflow['jobs'].get('plan', {})
    if isinstance(plan, dict):
        current_reuse = {'name': 'Reuse unchanged Windows qualification inputs', 'id': 'test-reuse',
                         'env': {'GH_TOKEN': '${{ github.token }}',
                                 'CI_ONLY': "${{ steps.plan.outputs.publish == 'false' && steps.plan.outputs.reuse != 'true' }}"},
                         'run': 'python .github/scripts/reuse_qualification.py plan'}
        for step in plan.get('steps', []):
            if step == current_reuse:
                step['name'] = 'Reuse unchanged same-PR qualification inputs'
                del step['env']['CI_ONLY']
        plan['steps'] = [step for step in plan.get('steps', []) if step != parser_step]
    publish = workflow['jobs'].get('publish', {})
    if isinstance(publish, dict):
        if publish.get('needs') == ['plan', 'ci-tools', 'assemble']:
            publish['needs'] = ['plan', 'assemble']
        condition = publish.get('if', '')
        publish['if'] = condition.replace(" && needs.ci-tools.result == 'success'", '', 1)
    for name, job in workflow['jobs'].items():
        require(isinstance(job, dict), 'Invalid workflow job')
        if name == 'validate':
            # Both forms execute the same checks for a fresh qualification.
            if job.get('if') == "needs.plan.outputs.reuse != 'true' && needs.plan.outputs.test_reuse != 'true'":
                job['if'] = "needs.plan.outputs.reuse != 'true'"
        steps = []
        for original in job.get('steps', []):
            step = copy.deepcopy(original)
            if name == 'validate' and step == {
                'name': 'Test artifact promotion and rejection policies', 'run': PYTHON_TEST,
            }:
                continue  # Moved, unchanged, to the always-run CI tools job.
            if (name == 'assemble' and step.get('id') == 'build-downloads'
                    and step.get('uses') == CACHE_ACTION
                    and step.get('with', {}).get('path') == '.cache'):
                settings = step['with']
                key = settings.get('key', '')
                old_key = key.replace('build-downloads-corepack-v1-', 'build-downloads-', 1)
                if key.startswith('build-downloads-corepack-v1-'):
                    settings['key'] = old_key
                    if settings.get('restore-keys') == old_key:
                        del settings['restore-keys']
            if name == 'assemble' and step.get('name') == 'Build and qualify Windows package':
                env = step.get('env', {})
                if env.get('COREPACK_HOME') == '${{ github.workspace }}/.cache/corepack':
                    del env['COREPACK_HOME']
                    if not env:
                        step.pop('env', None)
            if step.get('uses') == UPLOAD_ACTION and step.get('with', {}).get('name') in (
                    'qualified-windows-package-v1', 'migration-tools'):
                if step['with'].get('compression-level') in ('0', '6'):
                    del step['with']['compression-level']
            steps.append(step)
        if 'steps' in job:
            job['steps'] = steps
    return workflow


def remote_workflow(api, sha):
    blob = api.get(f'git/blobs/{sha}')
    require(blob.get('sha') == sha and blob.get('encoding') == 'base64',
            'Cannot verify workflow blob')
    return workflow_inputs(base64.b64decode(blob['content']).decode('utf-8'))


def inputs(api, tree):
    require(SHA.fullmatch(tree or ''), 'Invalid qualification input tree')
    data = api.get(f'git/trees/{tree}?recursive=1')
    require(data.get('sha') == tree and data.get('truncated') is False,
            'Cannot verify incomplete qualification inputs')
    entries = [e for e in data['tree'] if e['type'] != 'tree']
    require(len({e['path'] for e in entries}) == len(entries), 'Duplicate input paths')
    return {e['path']: (e['mode'], e['type'],
                        remote_workflow(api, e['sha']) if e['path'] == WORKFLOW else e['sha'])
            for e in entries if e['path'] not in RELEASE_TOOLS}


def matching_pr(run, pr, repo):
    if (run.get('event') != 'pull_request' or run.get('path') != WORKFLOW
            or run.get('repository', {}).get('full_name') != repo
            or run.get('head_repository', {}).get('full_name') != repo
            or run.get('head_branch') != pr['head']['ref']):
        return None
    matches = [p for p in run.get('pull_requests', []) if p['number'] == pr['number']]
    if len(matches) != 1:
        return None
    previous = matches[0]
    repo_id = run['repository']['id']
    if (previous['base']['ref'] != 'main' or previous['base']['sha'] != pr['base']['sha']
            or previous['head']['sha'] != run['head_sha']
            or previous['head']['repo']['id'] != repo_id
            or previous['base']['repo']['id'] != repo_id
            or run['head_repository']['id'] != repo_id):
        return None
    return previous


def validate_evidence(api, run, previous, jobs, artifact, record, source, workflow_id):
    """Validate the old open PR as it actually was, without pretending it merged."""
    require(run['workflow_id'] == workflow_id and run['path'] == WORKFLOW
            and run['event'] == 'pull_request' and run['status'] == 'completed'
            and run['conclusion'] == 'success', 'Prior PR qualification did not succeed')
    require(record.get('schemaVersion') == 1 and record.get('repository') == api.repo
            == run['repository']['full_name'] == run['head_repository']['full_name'],
            'Qualification repository mismatch')
    require(record['event'] == 'pull_request' and record['runId'] == run['id']
            and record['pullRequest'] == previous['number']
            and record['headCommit'] == run['head_sha'] == previous['head']['sha']
            and record['baseCommit'] == previous['base']['sha'], 'Qualification PR identity mismatch')
    if record['runAttempt'] != run['run_attempt']:
        raise NotReusable('Qualification belongs to an older run attempt')
    require(artifact['name'] == ARTIFACT and not artifact['expired']
            and DIGEST.fullmatch(artifact.get('digest') or ''), 'Invalid qualified artifact')
    provenance = artifact['workflow_run']
    require(provenance['id'] == run['id'] and provenance['head_sha'] == run['head_sha']
            and provenance['repository_id'] == provenance['head_repository_id']
            == run['repository']['id'] == run['head_repository']['id'],
            'Artifact belongs to another run/head/repository')
    for name in REQUIRED_JOBS:
        matches = [j for j in jobs if j['name'] == name and j['run_attempt'] == run['run_attempt']]
        require(len(matches) == 1 and matches[0]['status'] == 'completed'
                and matches[0]['conclusion'] == 'success', 'Required qualification job did not succeed')
    assemble = next(j for j in jobs if j['name'] == 'assemble' and j['run_attempt'] == run['run_attempt'])
    require(datetime.fromisoformat(assemble['started_at']) <= datetime.fromisoformat(artifact['created_at'])
            <= datetime.fromisoformat(assemble['completed_at']), 'Artifact belongs to another job attempt')
    require(SHA.fullmatch(record.get('sourceCommit', '')) and SHA.fullmatch(record.get('sourceTree', ''))
            and source['sha'] == record['sourceCommit'] and source['tree']['sha'] == record['sourceTree']
            and [p['sha'] for p in source['parents']] == [record['baseCommit'], record['headCommit']],
            'Recorded source is not the actual tested PR merge checkout')


def select(api, event):
    pr = event['pull_request']
    if not (pr['base']['ref'] == 'main' and pr['base']['repo']['full_name'] == api.repo
            and (pr['head'].get('repo') or {}).get('full_name') == api.repo):
        return None
    current = api.get(f"git/commits/{os.environ['GITHUB_SHA']}")
    require(current['sha'] == git('rev-parse', 'HEAD') == os.environ['GITHUB_SHA']
            and [p['sha'] for p in current['parents']] == [pr['base']['sha'], pr['head']['sha']],
            'Current PR checkout does not match the triggering base/head')
    current_inputs = inputs(api, current['tree']['sha'])
    workflow_id = api.get('actions/workflows/build-windows.yml')['id']
    version = pin_version(json.loads(Path('upstream.json').read_text(encoding='utf-8')))
    branch = urllib.parse.quote(pr['head']['ref'], safe='')
    path = f'actions/workflows/build-windows.yml/runs?event=pull_request&branch={branch}'
    # Bound API work. Not finding proof always means a fresh full qualification.
    for candidate in islice(api.pages(path, 'workflow_runs'), 20):
        if candidate['id'] == int(os.environ['GITHUB_RUN_ID']):
            continue
        run = api.get(f"actions/runs/{candidate['id']}")
        previous = matching_pr(run, pr, api.repo)
        if previous is None:
            continue
        # Never use an older green run to hide a newer failed or pending run.
        if run['status'] != 'completed' or run['conclusion'] != 'success':
            api.reuse_blocked = True
            return None
        jobs = list(api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", 'jobs'))
        artifacts = artifacts_for(api, run['id'])
        if not artifacts:
            # A preceding read-only reuse check has no new package. Follow back
            # to original immutable evidence; never trust a chain's own verdict.
            assemble = [j for j in jobs if j['name'] == 'assemble' and j['run_attempt'] == run['run_attempt']]
            if len(assemble) == 1 and assemble[0]['conclusion'] == 'skipped':
                continue
            return None
        require(len(artifacts) == 1, 'Ambiguous qualification artifacts')
        artifact = artifacts[0]
        try:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / 'qualified.zip'
                api.download(artifact, archive)
                record = validate_bundle(archive, root / 'package', version)
            source = api.get(f"git/commits/{record['sourceCommit']}")
            validate_evidence(api, run, previous, jobs, artifact, record, source, workflow_id)
            if inputs(api, source['tree']['sha']) != current_inputs or not unchanged_baseline(api, version, run, jobs):
                return None
        except NotReusable:
            return None
        except urllib.error.HTTPError as error:
            if error.code in (404, 410):
                return None
            raise
        return run, artifact, record
    return None


def read_job_log(api, job_id):
    # Logs are immutable evidence tied to the already-verified job attempt.
    # As with package downloads, never forward the token to storage redirects.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    try:
        response = urllib.request.build_opener(NoRedirect).open(
            api.request(f'actions/jobs/{job_id}/logs'), timeout=60)
    except urllib.error.HTTPError as error:
        if error.code in (404, 410):
            return ''
        if error.code != 302:
            raise
        url = error.headers['Location']
        require(urllib.parse.urlparse(url).scheme == 'https', 'Non-HTTPS log redirect')
        response = urllib.request.urlopen(url, timeout=60)
    with response:
        data = response.read(4 * 1024 * 1024 + 1)
    return data.decode('utf-8-sig') if len(data) <= 4 * 1024 * 1024 else ''


def unchanged_baseline(api, version, run, jobs):
    """The latest preceding released Windows package must predate the evidence.

    Release selection is external to Git. Bind the original job log baseline
    identity and require both digest-verified assets to predate that run.
    """
    target = tuple(map(int, version[1:].split('.')))
    eligible = [r for r in api.pages('releases') if not r['draft'] and not r['prerelease']
                and WINDOWS_VERSION.fullmatch(r['tag_name'])
                and tuple(map(int, r['tag_name'][1:].split('.'))) < target]
    if not eligible:
        return False
    assemble = [j for j in jobs if j['name'] == 'assemble'
                and j['run_attempt'] == run['run_attempt'] and j.get('status') == 'completed'
                and j['conclusion'] == 'success']
    if len(assemble) != 1:
        return False
    log = read_job_log(api, assemble[0]['id'])
    recorded = re.findall(r'^\d{4}-\d{2}-\d{2}T\S+Z Verified upgrade baseline: '
                          r'(v\d+\.\d+\.\d+\.\d+) \(v\d+\.\d+\.\d+, upstream [0-9a-f]{40}\) -> '
                          + re.escape(version) + r'\r?$', log, re.MULTILINE)
    if len(recorded) != 1:
        return False
    baseline = max(eligible, key=lambda r: tuple(map(int, r['tag_name'][1:].split('.'))))
    if baseline['tag_name'] != recorded[0]:
        return False
    cutoff = datetime.fromisoformat(run['created_at'])
    if any(not baseline.get(key) or datetime.fromisoformat(baseline[key]) > cutoff
           for key in ('published_at', 'updated_at')):
        return False
    for name in [a['name'] for a in baseline['assets'] if a['name'] != 'Install.cmd' and not a['name'].endswith('-migration-tools.zip')]:
        assets = [a for a in baseline['assets'] if a['name'] == name]
        if len(assets) != 1:
            return False
        asset = assets[0]
        if (not DIGEST.fullmatch(asset.get('digest') or '') or asset.get('size', 0) <= 0
                or any(not asset.get(key) or datetime.fromisoformat(asset[key]) > cutoff
                       for key in ('created_at', 'updated_at'))):
            return False
    return True


def select_main(api, event):
    """Use a successful trusted-main run for a non-release CI-only iteration."""
    pr = event.get('pull_request')
    if pr and not (pr['base']['ref'] == 'main' and pr['base']['repo']['full_name'] == api.repo
                   and (pr['head'].get('repo') or {}).get('full_name') == api.repo):
        return None
    current = api.get(f"git/commits/{os.environ['GITHUB_SHA']}")
    require(current['sha'] == git('rev-parse', 'HEAD') == os.environ['GITHUB_SHA'],
            'Current checkout does not match the triggering source')
    if pr:
        require([p['sha'] for p in current['parents']] == [pr['base']['sha'], pr['head']['sha']],
                'Current PR checkout does not match the triggering base/head')
    elif os.environ.get('GITHUB_REF') != 'refs/heads/main':
        return None
    current_inputs = inputs(api, current['tree']['sha'])
    version = pin_version(json.loads(Path('upstream.json').read_text(encoding='utf-8')))
    workflow_id = api.get('actions/workflows/build-windows.yml')['id']
    for candidate in islice(api.pages('actions/workflows/build-windows.yml/runs?event=push&branch=main', 'workflow_runs'), 20):
        if candidate['id'] == int(os.environ['GITHUB_RUN_ID']):
            continue
        run = api.get(f"actions/runs/{candidate['id']}")
        if (run.get('event') != 'push' or run.get('head_branch') != 'main'
                or run.get('path') != WORKFLOW or run.get('workflow_id') != workflow_id
                or run.get('repository', {}).get('full_name') != api.repo
                or run.get('head_repository', {}).get('full_name') != api.repo):
            continue
        # Never hide a failed/pending newer main qualification with older green.
        if run['status'] != 'completed' or run['conclusion'] != 'success':
            api.reuse_blocked = True
            return None
        jobs = list(api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", 'jobs'))
        artifacts = artifacts_for(api, run['id'])
        if not artifacts:
            assemble = [j for j in jobs if j['name'] == 'assemble' and j['run_attempt'] == run['run_attempt']]
            if len(assemble) == 1 and assemble[0]['conclusion'] == 'skipped':
                continue  # Find original evidence, never accept a reuse verdict.
            return None
        require(len(artifacts) == 1, 'Ambiguous qualification artifacts')
        artifact = artifacts[0]
        # Check input equality before downloading a potentially large package.
        source = api.get(f"git/commits/{run['head_sha']}")
        if inputs(api, source['tree']['sha']) != current_inputs or not unchanged_baseline(api, version, run, jobs):
            return None
        try:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / 'qualified.zip'
                api.download(artifact, archive)
                record = validate_bundle(archive, root / 'package', version)
            validate_provenance(record, run, jobs, artifact, source, source['tree']['sha'], api.repo)
            for name in REQUIRED_JOBS:
                matches = [j for j in jobs if j['name'] == name and j['run_attempt'] == run['run_attempt']]
                require(len(matches) == 1 and matches[0].get('status') == 'completed'
                        and matches[0]['conclusion'] == 'success', 'Required qualification job did not succeed')
            assemble = next(j for j in jobs if j['name'] == 'assemble' and j['run_attempt'] == run['run_attempt'])
            require(datetime.fromisoformat(assemble['started_at']) <= datetime.fromisoformat(artifact['created_at'])
                    <= datetime.fromisoformat(assemble['completed_at']), 'Artifact belongs to another job attempt')
        except NotReusable:
            return None
        except urllib.error.HTTPError as error:
            if error.code in (404, 410):
                return None
            raise
        return run, artifact, record
    return None


def plan():
    selected = None
    event_name = os.environ['GITHUB_EVENT_NAME']
    if event_name in ('pull_request', 'push'):
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
        api = API()
        if event_name == 'pull_request':
            selected = select(api, event)
        if selected is None and getattr(api, 'reuse_blocked', False) is not True and os.environ.get('CI_ONLY') == 'true':
            selected = select_main(api, event)
    output({'test_reuse': selected is not None})
    if selected:
        run, artifact, record = selected
        summary(f"Read-only CI reuse: product, build and Windows test inputs are unchanged. "
                f"Original tested checkout {record['sourceCommit']}; run {run['id']} attempt {run['run_attempt']}; "
                f"artifact {artifact['id']} ({artifact['digest']}). Current CI-tool tests run separately. "
                'No new package or release qualification is created; main promotion remains exact-tree only.')
    else:
        summary('No reusable Windows test evidence. Retain the complete build and qualification.')


def finish(directory=Path('dist')):
    """Metadata is staged early; it is eligible for upload only after all tests."""
    record = json.loads((directory / 'qualification.json').read_text(encoding='utf-8'))
    require(not git('status', '--porcelain', '--untracked-files=no'), 'Tracked source changed during qualification')
    require(record['sourceCommit'] == git('rev-parse', 'HEAD')
            and record['sourceTree'] == git('rev-parse', 'HEAD^{tree}'), 'Tested checkout changed')
    require(set(record['assets']) == package_filenames(directory, record['version']), 'Qualification asset list changed')
    require(all(sha256(directory / name) == digest for name, digest in record['assets'].items()),
            'Staged release asset changed during installation tests')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'finish'])
    args = parser.parse_args()
    plan() if args.command == 'plan' else finish()
