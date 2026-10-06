"""Reuse a completed same-PR qualification for release-tool-only iterations.

This is a read-only PR check shortcut, never a release promotion path. The old
package, source commit and qualification remain unchanged. Publishing still
requires qualified_release.py's exact merged-tree and mandatory-job checks.
"""
from datetime import datetime
from itertools import islice
import json
import os
from pathlib import Path
import tempfile
import urllib.error
import urllib.parse

from qualified_release import (
    API, ARTIFACT, DIGEST, REQUIRED_JOBS, SHA, WORKFLOW, NotReusable,
    artifacts_for, filenames, git, output, pin_version, require, sha256,
    summary, validate_bundle,
)

# Exact, unshipped files only. In particular, workflow definitions, this selector,
# all application/build/install/test files, pins and unknown paths remain inputs.
# README.md and the other docs are shipped in the package and are NOT excluded.
RELEASE_TOOLS = frozenset({
    '.github/scripts/qualified_release.py',
    '.github/scripts/publish_qualified.py',
    '.github/scripts/test_qualified_release.py',
    '.github/scripts/test_publish_qualified.py',
    'docs/development.md',
})


def inputs(api, tree):
    require(SHA.fullmatch(tree or ''), 'Invalid qualification input tree')
    data = api.get(f'git/trees/{tree}?recursive=1')
    require(data.get('sha') == tree and data.get('truncated') is False,
            'Cannot verify incomplete qualification inputs')
    entries = [e for e in data['tree'] if e['type'] != 'tree']
    require(len({e['path'] for e in entries}) == len(entries), 'Duplicate input paths')
    return {e['path']: (e['mode'], e['type'], e['sha']) for e in entries
            if e['path'] not in RELEASE_TOOLS}


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
            if inputs(api, source['tree']['sha']) != current_inputs:
                return None
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
    if os.environ['GITHUB_EVENT_NAME'] == 'pull_request':
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
        selected = select(API(), event)
    output({'test_reuse': selected is not None})
    if selected:
        run, artifact, record = selected
        summary(f"PR-only reuse: all package, build, install, test and workflow inputs are unchanged. "
                f"Original tested checkout {record['sourceCommit']}; run {run['id']} attempt {run['run_attempt']}; "
                f"artifact {artifact['id']} ({artifact['digest']}). Release-tool tests run again. "
                'No new package or release qualification is created; main promotion remains exact-tree only.')
    else:
        summary('No reusable same-PR test evidence. Retain the complete build and Windows qualification.')


def finish(directory=Path('dist')):
    """Metadata is staged early; it is eligible for upload only after all tests."""
    record = json.loads((directory / 'qualification.json').read_text(encoding='utf-8'))
    require(not git('status', '--porcelain', '--untracked-files=no'), 'Tracked source changed during qualification')
    require(record['sourceCommit'] == git('rev-parse', 'HEAD')
            and record['sourceTree'] == git('rev-parse', 'HEAD^{tree}'), 'Tested checkout changed')
    require(set(record['assets']) == filenames(record['version']), 'Qualification asset list changed')
    require(all(sha256(directory / name) == digest for name, digest in record['assets'].items()),
            'Staged release asset changed during installation tests')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'finish'])
    args = parser.parse_args()
    plan() if args.command == 'plan' else finish()
