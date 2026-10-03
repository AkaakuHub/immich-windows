"""Trusted-main completion of an explicitly dispatched upstream qualification.

Never check out, import, or execute files from the triggering run or artifact.
The candidate's archive is handled only as data by qualified_release.py.
"""
import json
from itertools import islice
import os
from pathlib import Path
import tempfile
import time
import urllib.error

from qualified_release import (
    API, SHA, WORKFLOW, ARTIFACT, artifacts_for, automated_run,
    automatic_candidate, automated_pr_identity, pin_version, require, summary, validate_automation_pr, verify,
)


def current_main(api):
    sha = api.get('git/ref/heads/main')['object']['sha']
    require(SHA.fullmatch(sha), 'Invalid current main identity')
    return sha


def verify_merge(api, pr, record, expected_base):
    commit = pr.get('merge_commit_sha') or ''
    require(pr['merged'] and commit == record['sourceCommit'] and SHA.fullmatch(commit),
            'Exact qualified merge was not confirmed')
    source = api.get(f'git/commits/{commit}')
    require(source['sha'] == commit and source['tree']['sha'] == record['sourceTree']
            and [p['sha'] for p in source['parents']] == [expected_base, record['headCommit']],
            'Merged source is not the exact qualified merge tree/parents; refusing publication')
    require(current_main(api) == commit, 'Main changed after automatic merge; refusing publication')
    return commit



def wait_for_indirect_merge(api, number, head, base, source_commit):
    # Updating main makes the PR head reachable, but GitHub may mark the PR
    # merged asynchronously. Poll metadata only; never repeat the ref write.
    for attempt in range(12):
        require(current_main(api) == source_commit, 'Main changed before merged-PR confirmation')
        pr = api.get(f'pulls/{number}')
        require(pr['head']['sha'] == head and pr['base']['ref'] == 'main', 'PR changed during merge confirmation')
        if pr['merged']:
            validate_automation_pr(pr, api.repo, number, head, base, merged=True)
            require(pr['merge_commit_sha'] == source_commit, 'PR does not identify the promoted merge commit')
            return pr
        require(pr['state'] == 'open', 'PR was closed without a confirmed merge')
        if attempt < 11:
            time.sleep(5)
    raise ValueError('Main contains the qualified commit but GitHub has not confirmed the PR merge; refusing publication')


def require_unprotected_main(api, base):
    # Do not exploit an administrator/app bypass of existing protection rules.
    # The API also enforces any rule introduced between this read and the write.
    branch = api.get('branches/main')
    require(branch.get('protected') is False and branch['commit']['sha'] == base,
            'Main is protected or changed; automatic ref promotion is blocked')
    require(api.get('rules/branches/main') == [], 'Main has repository rules; automatic ref promotion is blocked')

def complete(api, event_run, *, recover=False):
    require(type(event_run.get('id')) is int and event_run['id'] > 0, 'Invalid completion run identity')
    # Reread all authoritative state. workflow_run input is identification only.
    run = api.get(f"actions/runs/{event_run['id']}")
    identity = automated_run(run)
    if identity is None:
        summary('This is not an automatic upstream qualification; no merge or dispatch.')
        return
    require(run['id'] == event_run['id'] and run['run_attempt'] == event_run['run_attempt'],
            'Completion event belongs to a stale run attempt')
    require(run['path'] == WORKFLOW and run['status'] == 'completed' and run['conclusion'] == 'success'
            and run['repository']['full_name'] == api.repo == run['head_repository']['full_name'],
            'Only successful same-repository automatic qualifications may complete')
    number, head, base = identity
    prior = api.get(f'pulls/{number}')
    merged = prior['merged']
    pr, pin = automatic_candidate(api, number, head, base, merged=merged)
    if recover and merged and already_published(api, pin_version(pin)):
        return False
    if merged:
        source = api.get(f"git/commits/{pr['merge_commit_sha']}")
    else:
        require(current_main(api) == base and pr.get('mergeable') is not False,
                'Main moved or the PR is no longer mergeable; leave it open for a new qualification')
        merge_sha = pr.get('merge_commit_sha') or ''
        require(SHA.fullmatch(merge_sha), 'No current PR merge checkout')
        source = api.get(f'git/commits/{merge_sha}')
        require(source['sha'] == merge_sha and [p['sha'] for p in source['parents']] == [base, head],
                'Current PR merge checkout changed')
    artifacts = artifacts_for(api, run['id'])
    require(len(artifacts) == 1, f'Expected exactly one {ARTIFACT} artifact')
    artifact = artifacts[0]
    with tempfile.TemporaryDirectory() as temporary:
        record = verify(api, run, artifact, pin_version(pin), Path(temporary), pr,
                        target_tree=source['tree']['sha'], allow_open_automation=not merged)
    if not merged:
        # Do not ready a draft or mutate any PR until every immutable evidence
        # check has passed. Recheck after that mutation and just before merge.
        require_unprotected_main(api, base)
        if pr['draft']:
            api.ready_for_review(pr['node_id'])
        pr, _ = automatic_candidate(api, number, head, base)
        require(current_main(api) == base and pr.get('mergeable') is not False and not pr['draft'],
                'Automatic PR/base changed immediately before merge')
        merge_sha = pr.get('merge_commit_sha') or ''
        require(SHA.fullmatch(merge_sha), 'Current merge checkout disappeared before merge')
        current_source = api.get(f'git/commits/{merge_sha}')
        require(current_source['sha'] == merge_sha and current_source['tree']['sha'] == record['sourceTree']
                and [p['sha'] for p in current_source['parents']] == [base, head],
                'Current qualified merge checkout changed before merge')
        # Promote the already tested Git object, never synthesize a new merge
        # against a moving main. force:false atomically rejects divergent main
        # advancement without replacing anyone's commits. A concurrent ancestor
        # advancement can only land this same exact qualified destination.
        latest = api.get(f'pulls/{number}')
        validate_automation_pr(latest, api.repo, number, head, base)
        require(current_main(api) == base, 'Main advanced immediately before ref promotion')
        result = api.write('git/refs/heads/main', {'sha': record['sourceCommit'], 'force': False}, method='PATCH')
        require(result.get('ref') == 'refs/heads/main' and result.get('object', {}).get('sha') == record['sourceCommit'],
                'GitHub did not confirm the exact qualified ref update')
        pr = wait_for_indirect_merge(api, number, head, base, record['sourceCommit'])
    merge = verify_merge(api, pr, record, base)
    # GITHUB_TOKEN suppresses merge push-triggered workflows. Dispatch promotion
    # explicitly, bound to the verified run, artifact digest and merged commit.
    title = f"Promote qualified run {run['id']} at {merge}"
    recent = list(islice(api.pages(f'actions/workflows/build-windows.yml/runs?event=workflow_dispatch&head_sha={merge}', 'workflow_runs'), 100))
    for candidate in recent:
        if candidate.get('display_title') == title and candidate.get('head_sha') == merge:
            if not recover or candidate.get('status') != 'completed' or candidate.get('conclusion') == 'success':
                summary(f"Promotion was already attempted by run {candidate['id']}; no duplicate build or dispatch.")
                return False
            # Daily recovery may retry this failed publication continuation once.
            # The exact original qualification remains mandatory; no new build.
            summary(f"Retrying failed publication run {candidate['id']} using the same immutable artifact.")
            break
    else:
        require(len(recent) < 100, 'Promotion identity is outside the bounded lookup; refusing a duplicate dispatch')
    api.write('actions/workflows/build-windows.yml/dispatches', {'ref': 'main', 'inputs': {
        'component': 'all', 'qualified_run_id': str(run['id']),
        'qualified_artifact_id': str(artifact['id']), 'qualified_artifact_digest': artifact['digest'],
        'expected_merge': merge,
    }})
    summary(f"Merged qualified PR #{number} as {merge}; dispatched byte-for-byte promotion of artifact {artifact['id']} ({artifact['digest']}).")
    return True


def already_published(api, version):
    try:
        release = api.get(f'releases/tags/{version}')
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise
    require(release['tag_name'] == version, 'Unexpected release lookup')
    if not release['draft']:
        summary(f'{version} is already published; no recovery or build needed.')
        return True
    return False


def recover_completion(run_id):
    """One daily continuation of the current green qualification; never rebuild."""
    require(type(run_id) is int and run_id > 0, 'Invalid recovery run ID')
    api = API()
    run = api.get(f'actions/runs/{run_id}')
    identity = automated_run(run)
    require(identity is not None and run['status'] == 'completed' and run['conclusion'] == 'success',
            'Recovery requires the exact successful automatic qualification')
    title = f'Complete qualified run {run_id}'
    recent = list(islice(api.pages(f'actions/workflows/complete-upstream.yml/runs?event=workflow_run&head_sha={identity[2]}', 'workflow_runs'), 100))
    for candidate in recent:
        if candidate.get('display_title') == title:
            if candidate['status'] != 'completed' or candidate.get('conclusion') == 'success':
                summary(f'Completion for qualification {run_id} is pending or already succeeded; no duplicate continuation.')
                return False
            break
    else:
        require(len(recent) < 100, 'Completion identity is outside the bounded lookup; refusing a duplicate continuation')
    return bool(complete(api, run, recover=True))


def recover_publication(main, pin):
    """Recover only the current automatic main's missing/failed publication."""
    require(SHA.fullmatch(main), 'Invalid publication recovery main SHA')
    api = API()
    version = pin_version(pin)
    if current_main(api) != main or pin['windowsRevision'] != 0 or already_published(api, version):
        return False
    for association in api.pages(f'commits/{main}/pulls'):
        pr = api.get(f"pulls/{association['number']}")
        if not (pr.get('merged') and pr.get('merge_commit_sha') == main
                and pr['head'].get('ref') == 'automation/upstream-' + pin['version']
                and pr.get('user', {}).get('login') == 'github-actions[bot]'):
            continue
        identity = automated_pr_identity(pr)
        require(identity is not None, 'Cannot recover an unowned automatic main')
        number, head, base = identity
        validate_automation_pr(pr, api.repo, number, head, base, merged=True)
        title = f'Qualify upstream PR #{number} head={head} base={base}'
        # This exact base/head association bounds the search; never scan older
        # release history or bypass a newer failed/pending attempt for this head.
        runs = api.pages(f'actions/workflows/build-windows.yml/runs?event=workflow_dispatch&head_sha={base}', 'workflow_runs')
        latest = next((r for r in islice(runs, 100) if r.get('display_title') == title), None)
        if latest is None or latest['status'] != 'completed' or latest['conclusion'] != 'success':
            summary('Current automatic main has no current successful qualification evidence; no rebuild or publication.')
            return False
        return bool(complete(api, latest, recover=True))
    return False


if __name__ == '__main__':
    require(os.environ['GITHUB_EVENT_NAME'] == 'workflow_run'
            and os.environ['GITHUB_REF'] == 'refs/heads/main', 'Completion must run from trusted main')
    complete(API(), json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())['workflow_run'])
