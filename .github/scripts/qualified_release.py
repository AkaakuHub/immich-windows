"""Promote an immutable, qualified Actions artifact; never execute its contents.

Only merged same-repository PRs are eligible. GitHub's run/artifact/job records,
actual Git objects, and the now-reviewed main tree are the trust boundary.
No cache entry or artifact's self-reported success is accepted as test evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

WORKFLOW = '.github/workflows/build-windows.yml'
ARTIFACT = 'qualified-windows-package-v1'
REQUIRED_JOBS = {'validate', 'codec', 'postgres', 'assemble'}
MAX_BYTES = 1024 * 1024 * 1024
SHA = re.compile(r'^[0-9a-f]{40}$')
DIGEST = re.compile(r'^sha256:[0-9a-f]{64}$')


class NotReusable(ValueError):
    """Valid past evidence no longer describes this target; qualify it afresh."""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(*args):
    return subprocess.check_output(['git', *args], text=True, encoding='utf-8').removesuffix('\n')


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def filenames(version):
    require(re.fullmatch(r'v\d+\.\d+\.\d+\.\d+', version), 'Invalid Windows version')
    return {f'immich-windows-{version}-{suffix}.zip'
            for suffix in ('win-x64', 'native-dependencies', 'migration-tools')} | {'Install.cmd'}


def ci_only(paths):
    # Deliberately narrow. tests/, packaging/, runtime/, pins and unknown paths
    # can affect the shipped application and still require a new revision.
    return all(p == 'docs/development.md' or p.startswith('.github/') for p in paths)


class API:
    def __init__(self):
        self.repo = os.environ['GITHUB_REPOSITORY']
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', self.repo), 'Invalid repository')
        self.root = f'https://api.github.com/repos/{self.repo}/'

    def request(self, path):
        require(not path.startswith('/') and '://' not in path, 'Invalid API path')
        return urllib.request.Request(self.root + path, headers={
            'Authorization': f"Bearer {os.environ['GH_TOKEN']}",
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
        })

    def get(self, path):
        with urllib.request.urlopen(self.request(path), timeout=60) as response:
            return json.load(response)

    def pages(self, path, key=None):
        page = 1
        while True:
            data = self.get(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
            items = data[key] if key else data
            yield from items
            if len(items) < 100:
                break
            page += 1

    def download(self, artifact, destination):
        require(DIGEST.fullmatch(artifact.get('digest') or ''), 'Missing artifact SHA-256')
        require(0 < artifact['size_in_bytes'] <= MAX_BYTES, 'Artifact exceeds size limit')
        # Do not forward the GitHub token to the signed storage redirect.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(NoRedirect)
        try:
            response = opener.open(self.request(f"actions/artifacts/{artifact['id']}/zip"), timeout=60)
        except urllib.error.HTTPError as error:
            if error.code != 302:
                raise
            url = error.headers['Location']
            require(urllib.parse.urlparse(url).scheme == 'https', 'Non-HTTPS artifact redirect')
            response = urllib.request.urlopen(url, timeout=60)
        with response, open(destination, 'wb') as output:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                require(total <= MAX_BYTES, 'Downloaded artifact exceeds size limit')
                output.write(chunk)
        require('sha256:' + sha256(destination) == artifact['digest'], 'Artifact digest mismatch; refusing promotion')


def validate_bundle(archive, destination, version):
    with zipfile.ZipFile(archive) as bundle:
        require(bundle.getinfo('qualification.json').file_size < 64 * 1024, 'Oversized qualification record')
        record = json.loads(bundle.read('qualification.json'))
        require(record.get('schemaVersion') == 1, 'Qualification schema mismatch')
        recorded_version = record.get('version', '')
        expected = filenames(recorded_version)
        entries = bundle.infolist()
        require(len(entries) == 5 and {e.filename for e in entries} == expected | {'qualification.json'},
                'Artifact must contain exactly four release assets and qualification.json')
        require(all(e.file_size <= MAX_BYTES and not e.is_dir() and not (e.external_attr >> 16 & 0o170000 == 0o120000)
                    for e in entries) and sum(e.file_size for e in entries) <= MAX_BYTES,
                'Unsafe or oversized artifact entries')
        require(set(record.get('assets', {})) == expected, 'Qualification asset list mismatch')
        destination.mkdir(parents=True, exist_ok=True)
        for name in expected:
            # Exact allowlist filenames, not extractall: no paths, links or code execution.
            target = destination / name
            with bundle.open(name) as source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
            require(sha256(target) == record['assets'][name], f'Asset hash mismatch: {name}')
    app = destination / f'immich-windows-{recorded_version}-win-x64.zip'
    with zipfile.ZipFile(app) as package:
        name = f'immich-windows-{recorded_version}-win-x64/manifest.json'
        require(package.getinfo(name).file_size < 4 * 1024 * 1024, 'Oversized package manifest')
        manifest = json.loads(package.read(name))
        require(manifest['packageVersion'] == recorded_version and manifest['sourceCommit'] == record['sourceCommit'],
                'Packaged source/version disagrees with qualification')
    if recorded_version != version:
        raise NotReusable('Qualified package version differs from the target version')
    return record


def validate_provenance(record, run, jobs, artifact, source, target_tree, repo, pr=None):
    require(record.get('repository') == repo == run['repository']['full_name'] == run['head_repository']['full_name'],
            'Repository provenance mismatch')
    require(run['path'] == WORKFLOW and run['conclusion'] == 'success' and run['status'] == 'completed',
            'Qualification workflow has not succeeded')
    require(record['runId'] == run['id'], 'Wrong run identity')
    if record['runAttempt'] != run['run_attempt']:
        raise NotReusable('Artifact belongs to a previous run attempt')
    require(artifact['workflow_run']['repository_id'] == artifact['workflow_run']['head_repository_id'] == run['repository']['id'] == run['head_repository']['id'],
            'Artifact repository identity mismatch')
    require(artifact['workflow_run']['id'] == run['id'] and artifact['workflow_run']['head_sha'] == run['head_sha'],
            'Artifact belongs to another run/head')
    require(artifact['name'] == ARTIFACT and not artifact['expired'], 'Missing or expired qualified artifact')
    successes = {j['name'] for j in jobs if j['conclusion'] == 'success' and j['run_attempt'] == run['run_attempt']}
    require(REQUIRED_JOBS <= successes, 'Mandatory qualification jobs were skipped or did not succeed')
    require(SHA.fullmatch(record['sourceCommit']) and SHA.fullmatch(record['sourceTree']), 'Invalid source Git object')
    require(source['sha'] == record['sourceCommit'] and source['tree']['sha'] == record['sourceTree'], 'Recorded Git object mismatch')
    if record['sourceTree'] != target_tree:
        raise NotReusable('Tested source differs from the merged tree')
    if pr is not None:
        require(run['event'] == record['event'] == 'pull_request', 'Not a PR qualification')
        require(pr['merged'] and pr['base']['ref'] == 'main' and pr['head']['repo']['full_name'] == repo,
                'PR is not a merged same-repository main PR')
        require(record['pullRequest'] == pr['number'] and record['headCommit'] == run['head_sha'] == pr['head']['sha'],
                'Qualified PR head differs from the merged PR')
        parents = [p['sha'] for p in source['parents']]
        require(parents == [record['baseCommit'], record['headCommit']], 'Not the recorded PR merge checkout')
        if record['baseCommit'] != pr['base']['sha']:
            raise NotReusable('PR base changed since qualification')
    else:
        require(run['event'] == record['event'] and run['event'] in ('push', 'workflow_dispatch'), 'Wrong main build event')
        require(record['sourceCommit'] == run['head_sha'] and run['head_branch'] == 'main', 'Not a main build')


def record_bundle(version, directory):
    require(not git('status', '--porcelain', '--untracked-files=no'), 'Tracked source changed during qualification')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    pr = event.get('pull_request', {})
    record = dict(schemaVersion=1, repository=os.environ['GITHUB_REPOSITORY'], version=version,
                  runId=int(os.environ['GITHUB_RUN_ID']), runAttempt=int(os.environ['GITHUB_RUN_ATTEMPT']),
                  event=os.environ['GITHUB_EVENT_NAME'], sourceCommit=git('rev-parse', 'HEAD'),
                  sourceTree=git('rev-parse', 'HEAD^{tree}'), pullRequest=pr.get('number'),
                  headCommit=pr.get('head', {}).get('sha'), baseCommit=pr.get('base', {}).get('sha'),
                  assets={name: sha256(directory / name) for name in sorted(filenames(version))})
    require(record['sourceCommit'] == os.environ['GITHUB_SHA'], 'Checkout is not the workflow-triggering source')
    (directory / 'qualification.json').write_text(json.dumps(record, indent=2) + '\n')


def release_policy(api, version):
    releases = list(api.pages('releases'))
    published = [r for r in releases if not r['draft'] and re.fullmatch(r'v\d+\.\d+\.\d+(\.\d+)?', r['tag_name'])]
    def number(v):
        result = tuple(map(int, v[1:].split('.')))
        return result + (0,) * (4 - len(result))
    newer = [r for r in published if number(r['tag_name']) > number(version)]
    require(not newer, f'{version} is older than a published release; increment windowsRevision')
    same = [r for r in published if r['tag_name'] == version]
    require(not any(r['draft'] and r['tag_name'] == version for r in releases), 'A draft for this revision already exists; inspect it before retrying')
    if not same:
        return True
    # Compare Git trees, not three-dot compare API (which can omit divergent changes).
    git('fetch', '--no-tags', 'origin', f'refs/tags/{version}')
    changed = git('diff', '--no-renames', '--name-only', '-z', 'FETCH_HEAD', 'HEAD').split('\0')
    require(ci_only(p for p in changed if p), f'{version} is already published and shipped inputs changed; increment windowsRevision')
    print(f'{version} is already published; CI/documentation-only verification, no new application release')
    return False


def output(values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        for key, value in values.items():
            require('\n' not in str(value) and '\r' not in str(value), 'Invalid output')
            stream.write(f'{key}={str(value).lower() if isinstance(value, bool) else value}\n')


def summary(message):
    print(message)
    if path := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(path, 'a') as stream:
            stream.write(message + '\n')


def artifacts_for(api, run_id):
    return [a for a in api.pages(f'actions/runs/{run_id}/artifacts', 'artifacts')
            if a['name'] == ARTIFACT and not a['expired']]


def verify(api, run, artifact, version, destination, pr=None, allow_original_attempt=False):
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / 'bundle.zip'
        try:
            api.download(artifact, archive)
        except urllib.error.HTTPError as error:
            if error.code in (404, 410):
                raise NotReusable('Qualified artifact is no longer available') from error
            raise
        record = validate_bundle(archive, destination, version)
    require(SHA.fullmatch(record.get('sourceCommit', '')), 'Invalid source commit')
    workflow = api.get('actions/workflows/build-windows.yml')
    require(run['workflow_id'] == workflow['id'], 'Unexpected qualification workflow identity')
    if allow_original_attempt and record['runAttempt'] != run['run_attempt']:
        original = record['runAttempt']
        require(type(original) is int and 0 < original < run['run_attempt'], 'Invalid original qualification attempt')
        attempt = api.get(f"actions/runs/{run['id']}/attempts/{original}")
        require(attempt['id'] == run['id'] and attempt['head_sha'] == run['head_sha']
                and attempt['status'] == 'completed' and attempt['run_attempt'] == original, 'Wrong original run attempt')
        # Only a retry of this same main publisher may use earlier successful
        # qualification jobs. All four must have succeeded in that one attempt.
        run = dict(attempt, conclusion='success')
    try:
        source = api.get(f"git/commits/{record['sourceCommit']}")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise NotReusable('Historical tested Git object is no longer available') from error
        raise
    jobs = list(api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", 'jobs'))
    validate_provenance(record, run, jobs, artifact, source, git('rev-parse', 'HEAD^{tree}'), api.repo, pr)
    return record


def plan():
    api = API()
    pin = json.loads(Path('upstream.json').read_text())
    version = f"{pin['version']}.{pin['windowsRevision']}"
    values = dict(version=version, publish=False, reuse=False, artifact_id='', artifact_digest='', run_id='', source_commit='')
    component = os.environ.get('COMPONENT', '')
    if os.environ['GITHUB_EVENT_NAME'] == 'workflow_dispatch' and component not in ('', 'all'):
        output(values)
        return
    values['publish'] = release_policy(api, version)
    if os.environ['GITHUB_EVENT_NAME'] == 'push' and os.environ['GITHUB_REF'] == 'refs/heads/main':
        sha = os.environ['GITHUB_SHA']
        pulls = list(api.pages(f'commits/{sha}/pulls'))
        for candidate in pulls:
            pr = api.get(f"pulls/{candidate['number']}")
            if not (pr['merged'] and pr['merge_commit_sha'] == sha and pr['base']['ref'] == 'main'
                    and pr['head'].get('repo') and pr['head']['repo']['full_name'] == api.repo):
                continue
            runs = api.pages(f"actions/workflows/build-windows.yml/runs?event=pull_request&head_sha={pr['head']['sha']}", 'workflow_runs')
            for run in runs:
                # Do not bypass a newer failed/pending qualification with an older green run.
                if run['status'] != 'completed' or run['conclusion'] != 'success' or run['head_repository']['full_name'] != api.repo:
                    break
                artifacts = artifacts_for(api, run['id'])
                if not artifacts:
                    break  # Expired/missing evidence: perform a fresh qualification.
                require(len(artifacts) == 1, 'Ambiguous qualification artifacts')
                artifact = artifacts[0]
                with tempfile.TemporaryDirectory() as temporary:
                    try:
                        record = verify(api, run, artifact, version, Path(temporary), pr)
                    except NotReusable as error:
                        summary(f'Fresh qualification required: {error}')
                        break
                values.update(reuse=True, artifact_id=artifact['id'], artifact_digest=artifact['digest'],
                              run_id=run['id'], source_commit=record['sourceCommit'])
                summary(f"Reusing qualified PR #{pr['number']} run {run['id']} attempt {run['run_attempt']}; identical Git tree {record['sourceTree']}. No repeated build or tests. Artifact {artifact['id']} ({artifact['digest']}).")
                output(values)
                return
    summary('No reusable qualification selected. Run the full build and test gate once.')
    output(values)


def prepare_publish(version, directory):
    api = API()
    source_run = int(os.environ.get('QUALIFIED_RUN_ID') or os.environ['GITHUB_RUN_ID'])
    run = api.get(f'actions/runs/{source_run}')
    # In this run, publish is pending, so overall run conclusion is not yet success.
    # We still require every mandatory build/test job of this exact attempt to succeed.
    same_run = source_run == int(os.environ['GITHUB_RUN_ID'])
    if same_run:
        run = dict(run, status='completed', conclusion='success')
    artifacts = artifacts_for(api, source_run)
    require(len(artifacts) == 1, 'Expected one immutable qualified artifact')
    artifact = artifacts[0]
    pr = None
    if not same_run:
        require(str(artifact['id']) == os.environ['QUALIFIED_ARTIFACT_ID'] and artifact['digest'] == os.environ['QUALIFIED_ARTIFACT_DIGEST'],
                'Selected artifact identity changed')
        for candidate in api.pages(f"commits/{os.environ['GITHUB_SHA']}/pulls"):
            current = api.get(f"pulls/{candidate['number']}")
            if current['merge_commit_sha'] == os.environ['GITHUB_SHA'] and current['head']['sha'] == run['head_sha']:
                pr = current
                break
        require(pr is not None, 'Merged PR association disappeared')
    require(not same_run or run['head_sha'] == os.environ['GITHUB_SHA'], 'Publisher run is not the current main commit')
    record = verify(api, run, artifact, version, directory, pr, allow_original_attempt=same_run)
    output({'source_commit': record['sourceCommit'], 'source_tree': record['sourceTree'], 'run_id': source_run,
            'artifact_id': artifact['id'], 'artifact_digest': artifact['digest']})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'record', 'prepare-publish'])
    parser.add_argument('--version')
    parser.add_argument('--directory', type=Path, default=Path('dist'))
    args = parser.parse_args()
    if args.command == 'plan':
        plan()
    elif args.command == 'record':
        record_bundle(args.version, args.directory)
    else:
        prepare_publish(args.version, args.directory)
