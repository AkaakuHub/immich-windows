"""Promote an immutable, qualified Actions artifact; never execute its contents.

Only verified same-repository PRs and trusted main dispatches are eligible. GitHub's run/artifact/job records,
actual Git objects, and the now-reviewed main tree are the trust boundary.
No cache entry or artifact's self-reported success is accepted as test evidence.
"""
import argparse
import base64
from datetime import datetime
import hashlib
from itertools import islice
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
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
NUMBER = r'(?:0|[1-9][0-9]*)'
STABLE_VERSION = re.compile(rf'v{NUMBER}\.{NUMBER}\.{NUMBER}')
WINDOWS_VERSION = re.compile(rf'v{NUMBER}\.{NUMBER}\.{NUMBER}\.{NUMBER}')
AUTOMATION_MARKER = '<!-- immich-windows:automatic-upstream:v1 -->'
AUTOMATION_OWNERSHIP = re.compile(r'<!-- immich-windows:automatic-head ([0-9a-f]{40}) base ([0-9a-f]{40}) -->')
AUTOMATION_TITLE = re.compile(r'Qualify upstream PR #([1-9][0-9]*) head=([0-9a-f]{40}) base=([0-9a-f]{40})')
AUTOMATION_JOBS = REQUIRED_JOBS | {'plan'}



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


def filenames(version, dependency_assets=()):
    require(WINDOWS_VERSION.fullmatch(version), 'Invalid Windows version')
    dependency_assets = tuple(dependency_assets)
    require(all(re.fullmatch(r'dependency-[0-9a-f]{64}', name) for name in dependency_assets), 'Invalid dependency asset name')
    return {f'immich-windows-{version}-{suffix}.zip'
            for suffix in ('win-x64', 'migration-tools')} | {'Install.cmd'} | set(dependency_assets)


def record_filenames(record):
    dependencies = set(record['assets']) - filenames(record['version'])
    expected = filenames(record['version'], dependencies)
    require(all(record['assets'][name] == name.removeprefix('dependency-') for name in dependencies),
            'Dependency asset identity mismatch')
    return expected


def package_filenames(directory, version):
    with zipfile.ZipFile(directory / f'immich-windows-{version}-win-x64.zip') as package:
        manifest = json.loads(package.read(f'immich-windows-{version}-win-x64/manifest.json').decode('utf-8-sig'))
    return filenames(version, (payload['assetName'] for payload in manifest['dependencyPayloads'].values()))


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

    def write(self, path, data, method='POST'):
        request = self.request(path)
        request.method = method
        request.add_header('Content-Type', 'application/json')
        request.data = json.dumps(data).encode() if data is not None else None
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
            return json.loads(body) if body else None

    def ready_for_review(self, node_id):
        # GitHub has no REST mutation for draft -> ready. The ID comes from the
        # already verified PR response, never interpolated into GraphQL source.
        request = self.request('')
        request.full_url = 'https://api.github.com/graphql'
        request.method = 'POST'
        request.add_header('Content-Type', 'application/json')
        request.data = json.dumps({
            'query': 'mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id}){pullRequest{id isDraft}}}',
            'variables': {'id': node_id},
        }).encode()
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)
        require(not result.get('errors'), 'Could not mark the verified PR ready for review')
        pull = result['data']['markPullRequestReadyForReview']['pullRequest']
        require(pull['id'] == node_id and pull['isDraft'] is False, 'Draft transition was not confirmed')

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



def positive_id(value, label):
    require(isinstance(value, str) and re.fullmatch(r'[1-9][0-9]*', value), f'Invalid {label}')
    return int(value)


def pin_version(pin):
    require(STABLE_VERSION.fullmatch(pin.get('version', '')), 'Invalid stable upstream version')
    revision = pin.get('windowsRevision')
    require(type(revision) is int and revision >= 0, 'Invalid Windows revision')
    return f"{pin['version']}.{revision}"


def remote_pin(api, commit):
    require(SHA.fullmatch(commit), 'Invalid pin commit')
    data = api.get(f'contents/upstream.json?ref={commit}')
    require(data['encoding'] == 'base64' and data.get('size', 0) < 65536, 'Invalid upstream pin response')
    return json.loads(base64.b64decode(data['content'], validate=False))


def automated_run(run):
    match = AUTOMATION_TITLE.fullmatch(run.get('display_title', ''))
    if not match:
        return None
    number, head, base = match.groups()
    require(run['event'] == 'workflow_dispatch' and run['head_branch'] == 'main'
            and run['head_sha'] == base, 'Automation must dispatch the exact trusted main base')
    return int(number), head, base


def validate_automation_pr(pr, repo, number, head, base, *, merged=False):
    require(type(number) is int and number > 0 and SHA.fullmatch(head) and SHA.fullmatch(base),
            'Invalid automatic PR identity')
    require(pr['number'] == number and pr['base']['ref'] == 'main'
            and pr['base']['repo']['full_name'] == repo
            and (pr['head'].get('repo') or {}).get('full_name') == repo,
            'Automation requires a same-repository PR into main')
    allowed_bases = {base}
    if merged and SHA.fullmatch(pr.get('merge_commit_sha') or ''):
        # Indirect merge metadata may already expose the promoted base. The
        # immutable qualification's ordered Git parents prove the original base.
        allowed_bases.add(pr['merge_commit_sha'])
    require(pr['head']['sha'] == head and pr['base']['sha'] in allowed_bases,
            'Automatic PR head or base changed')
    require(AUTOMATION_OWNERSHIP.findall(pr.get('body') or '') == [(head, base)],
            'Automatic branch ownership changed or is ambiguous')
    require(pr['user']['login'] == 'github-actions[bot]' and pr['user']['type'] == 'Bot'
            and AUTOMATION_MARKER in (pr.get('body') or ''), 'PR was not created by the upstream updater')
    branch = pr['head']['ref']
    require(branch.startswith('automation/upstream-') and STABLE_VERSION.fullmatch(branch.removeprefix('automation/upstream-')),
            'Unapproved automatic branch')
    require(pr['merged'] is merged and pr['state'] == ('closed' if merged else 'open'),
            'Automatic PR is not in the required open/merged state')
    return branch.removeprefix('automation/upstream-')



def automated_pr_identity(pr):
    ownership = AUTOMATION_OWNERSHIP.findall(pr.get('body') or '')
    if len(ownership) != 1 or ownership[0][0] != pr['head']['sha']:
        return None
    return pr['number'], ownership[0][0], ownership[0][1]

def automation_changes(api, head, base):
    # Compare complete Git trees rather than the compare API's 300-file limit.
    trees = []
    for commit in (base, head):
        tree = api.get(f'git/trees/{commit}?recursive=1')
        require(not tree.get('truncated', True), 'Cannot verify a truncated automation tree')
        entries = {entry['path']: (entry['mode'], entry['type'], entry['sha'])
                   for entry in tree['tree'] if entry['type'] != 'tree'}
        trees.append(entries)
    before, after = trees
    changed = {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}
    require('upstream.json' in changed, 'Automatic update did not change its upstream pin')
    for path in changed:
        allowed = path in ('upstream.json', 'dependencies/versions.json', 'patches/series', 'metadata-patches/series') or (
            path.startswith(('patches/server/', 'patches/machine-learning/', 'metadata-patches/server/')) and path.endswith('.patch'))
        require(allowed and all(part not in ('', '.', '..', '.git') for part in path.split('/'))
                and '\\' not in path and ':' not in path,
                f'Automatic update changed a disallowed path: {path}')
        for tree in trees:
            require(path not in tree or tree[path][:2] == ('100644', 'blob'),
                    'Automatic updates may change only regular, non-executable files')


def automatic_candidate(api, number, head, base, *, merged=False):
    pr = api.get(f'pulls/{number}')
    version = validate_automation_pr(pr, api.repo, number, head, base, merged=merged)
    # GitHub computes mergeability asynchronously on PR creation/readiness.
    # Only refresh API metadata, never rebuild or retry qualification tests.
    for _ in range(12):
        if merged or pr.get('mergeable') is not None:
            break
        merge_sha = pr.get('merge_commit_sha') or ''
        if SHA.fullmatch(merge_sha):
            try:
                source = api.get(f'git/commits/{merge_sha}')
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
            else:
                # An exact existing synthetic merge proves the fresh checkout
                # even while GitHub is recomputing its optional boolean cache.
                if source['sha'] == merge_sha and [p['sha'] for p in source['parents']] == [base, head]:
                    break
        time.sleep(5)
        pr = api.get(f'pulls/{number}')
        validate_automation_pr(pr, api.repo, number, head, base, merged=merged)
    automation_changes(api, head, base)
    pin = remote_pin(api, head)
    require(pin_version(pin) == version + '.0', 'Automatic upstream releases must start at revision zero')
    require(pin.get('repository') == 'https://github.com/immich-app/immich.git'
            and pin.get('channel') == 'stable' and SHA.fullmatch(pin.get('commit', '')),
            'Automatic update has an invalid official upstream pin')
    return pr, pin


def dispatch_inputs():
    path = os.environ.get('GITHUB_EVENT_PATH')
    return json.loads(Path(path).read_text(encoding='utf-8')).get('inputs', {}) if path else {}


def plan_automatic(api, inputs, values):
    require(os.environ['GITHUB_REF'] == 'refs/heads/main' and inputs.get('component') == 'all',
            'Automatic qualification requires a complete build dispatched on main')
    number = positive_id(inputs.get('upstream_pr'), 'upstream PR')
    head, base = inputs.get('expected_head', ''), inputs.get('expected_base', '')
    require(SHA.fullmatch(head) and SHA.fullmatch(base) and os.environ['GITHUB_SHA'] == base,
            'Automatic dispatch does not match its trusted main base')
    pr, pin = automatic_candidate(api, number, head, base)
    require(api.get('git/ref/heads/main')['object']['sha'] == base, 'Main advanced before qualification')
    require(pr.get('mergeable') is not False and SHA.fullmatch(pr.get('merge_commit_sha') or ''),
            'Automatic PR is conflicting or GitHub has not prepared its merge checkout')
    source = api.get(f"git/commits/{pr['merge_commit_sha']}")
    require(source['sha'] == pr['merge_commit_sha'] and [p['sha'] for p in source['parents']] == [base, head],
            'Automatic PR merge checkout does not match its exact base/head')
    version = pin_version(pin)
    require(release_policy(api, version), 'Automatic revision is already published')
    values.update(version=version, publish=False, checkout=source['sha'])
    summary(f"Qualifying automatic PR #{number} head {head} against main {base}; no publication before merge.")
    output(values)


def selected_promotion(api, inputs, version):
    require(os.environ['GITHUB_REF'] == 'refs/heads/main' and inputs.get('component') == 'all'
            and inputs.get('expected_merge') == os.environ['GITHUB_SHA'], 'Promotion must target its exact merged main commit')
    require(api.get('git/ref/heads/main')['object']['sha'] == os.environ['GITHUB_SHA'], 'Main advanced before promotion')
    run_id = positive_id(inputs.get('qualified_run_id'), 'qualification run')
    artifact_id = positive_id(inputs.get('qualified_artifact_id'), 'qualification artifact')
    digest = inputs.get('qualified_artifact_digest', '')
    require(DIGEST.fullmatch(digest), 'Invalid promotion artifact digest')
    run = api.get(f'actions/runs/{run_id}')
    identity = automated_run(run)
    require(identity is not None, 'Explicit promotion requires an automatic qualification')
    number, head, base = identity
    pr, _ = automatic_candidate(api, number, head, base, merged=True)
    require(pr['merge_commit_sha'] == os.environ['GITHUB_SHA'], 'Promotion is not the automatic PR merge')
    artifacts = artifacts_for(api, run_id)
    require(len(artifacts) == 1 and artifacts[0]['id'] == artifact_id and artifacts[0]['digest'] == digest,
            'Exact qualification artifact is missing or changed; refusing to rebuild')
    with tempfile.TemporaryDirectory() as temporary:
        record = verify(api, run, artifacts[0], version, Path(temporary), pr)
    return pr, run, artifacts[0], record

def validate_bundle(archive, destination, version):
    with zipfile.ZipFile(archive) as bundle:
        require(bundle.getinfo('qualification.json').file_size < 64 * 1024, 'Oversized qualification record')
        record = json.loads(bundle.read('qualification.json'))
        require(record.get('schemaVersion') == 1, 'Qualification schema mismatch')
        recorded_version = record.get('version', '')
        expected = record_filenames(record)
        entries = bundle.infolist()
        require(len(entries) == len(expected) + 1 and {e.filename for e in entries} == expected | {'qualification.json'},
                'Artifact must contain exactly the listed release assets and qualification.json')
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
        require(filenames(recorded_version, (payload['assetName'] for payload in manifest['dependencyPayloads'].values())) == expected,
                'Packaged dependency asset list disagrees with qualification')
        require(manifest['packageVersion'] == recorded_version and manifest['sourceCommit'] == record['sourceCommit'],
                'Packaged source/version disagrees with qualification')
    if recorded_version != version:
        raise NotReusable('Qualified package version differs from the target version')
    return record


def validate_provenance(record, run, jobs, artifact, source, target_tree, repo, pr=None, *, allow_open_automation=False):
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
        require((pr['merged'] or (allow_open_automation and record['event'] == 'workflow_dispatch')) and pr['base']['ref'] == 'main' and pr['head']['repo']['full_name'] == repo,
                'PR is not a merged same-repository main PR')
        require(record['pullRequest'] == pr['number'] and record['headCommit'] == pr['head']['sha'],
                'Qualified PR head differs from the merged PR')
        if record['event'] == 'workflow_dispatch':
            identity = automated_run(run)
            require(identity == (pr['number'], record['headCommit'], record['baseCommit']),
                    'Automatic dispatch provenance mismatch')
            validate_automation_pr(pr, repo, *identity, merged=not allow_open_automation)
            if not allow_open_automation:
                require(pr['merge_commit_sha'] == record['sourceCommit'],
                        'Automatic main is not the exact already-qualified merge commit')
            require(record.get('automation') == 'upstream-v1' and AUTOMATION_JOBS <= successes,
                    'Automatic qualification did not pass its trusted plan')
            for name in AUTOMATION_JOBS:
                matches = [j for j in jobs if j['name'] == name and j['run_attempt'] == run['run_attempt']]
                require(len(matches) == 1 and matches[0].get('status') == 'completed'
                        and matches[0]['conclusion'] == 'success', 'Automatic gate is not uniquely terminal and successful')
        else:
            require(run['event'] == record['event'] == 'pull_request' and record['headCommit'] == run['head_sha'],
                    'Not a PR qualification')
        parents = [p['sha'] for p in source['parents']]
        require(parents == [record['baseCommit'], record['headCommit']], 'Not the recorded PR merge checkout')
        allowed_bases = {record['baseCommit']}
        if record['event'] == 'workflow_dispatch' and not allow_open_automation:
            allowed_bases.add(record['sourceCommit'])
        if pr['base']['sha'] not in allowed_bases:
            raise NotReusable('PR base changed since qualification')
    else:
        require(run['event'] == record['event'] and run['event'] in ('push', 'workflow_dispatch'), 'Wrong main build event')
        require(record['sourceCommit'] == run['head_sha'] and run['head_branch'] == 'main', 'Not a main build')


def record_bundle(version, directory):
    require(not git('status', '--porcelain', '--untracked-files=no'), 'Tracked source changed during qualification')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    pr = event.get('pull_request', {})
    record = dict(schemaVersion=1, repository=os.environ['GITHUB_REPOSITORY'], version=version,
                  runId=int(os.environ['GITHUB_RUN_ID']), runAttempt=int(os.environ['GITHUB_RUN_ATTEMPT']),
                  event=os.environ['GITHUB_EVENT_NAME'], sourceCommit=git('rev-parse', 'HEAD'),
                  sourceTree=git('rev-parse', 'HEAD^{tree}'), pullRequest=pr.get('number'),
                  headCommit=pr.get('head', {}).get('sha'), baseCommit=pr.get('base', {}).get('sha'),
                  assets={name: sha256(directory / name) for name in sorted(package_filenames(directory, version))})
    inputs = event.get('inputs', {})
    if record['event'] == 'workflow_dispatch' and inputs.get('upstream_pr'):
        record.update(automation='upstream-v1', pullRequest=positive_id(inputs['upstream_pr'], 'upstream PR'),
                      headCommit=inputs['expected_head'], baseCommit=inputs['expected_base'])
        require(os.environ['GITHUB_REF'] == 'refs/heads/main' and record['baseCommit'] == os.environ['GITHUB_SHA']
                and record['sourceCommit'] == os.environ.get('QUALIFICATION_SOURCE'), 'Wrong automatic source checkout')
        parents = [line.removeprefix('parent ') for line in git('cat-file', '-p', 'HEAD').splitlines()
                   if line.startswith('parent ')]
        require(parents == [record['baseCommit'], record['headCommit']], 'Wrong automatic checkout parents')
    else:
        require(record['sourceCommit'] == os.environ['GITHUB_SHA'], 'Checkout is not the workflow-triggering source')
    (directory / 'qualification.json').write_text(json.dumps(record, indent=2) + '\n')


def release_policy(api, version, resume=None):
    releases = list(islice(api.pages('releases'), 100)) if resume is not None else list(api.pages('releases'))
    published = [r for r in releases if not r['draft'] and (STABLE_VERSION.fullmatch(r['tag_name']) or WINDOWS_VERSION.fullmatch(r['tag_name']))]
    def number(v):
        result = tuple(map(int, v[1:].split('.')))
        return result + (0,) * (4 - len(result))
    newer = [r for r in published if number(r['tag_name']) > number(version)]
    require(not newer, f'{version} is older than a published release; increment windowsRevision')
    same = [r for r in published if r['tag_name'] == version]
    drafts = [r for r in releases if r['draft'] and r['tag_name'] == version]
    if drafts and resume is not None:
        from publish_qualified import validate_release, validate_tag
        require(len(drafts) == 1, 'Ambiguous draft releases')
        record, artifact, commit = resume
        validate_release(drafts[0], record, artifact, commit)
        validate_tag(api, version, commit, missing_allowed=True)
    else:
        require(not drafts, 'A draft for this revision already exists; inspect it before retrying')
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


def verify(api, run, artifact, version, destination, pr=None, allow_original_attempt=False, target_tree=None, allow_open_automation=False):
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
    validate_provenance(record, run, jobs, artifact, source, target_tree or git('rev-parse', 'HEAD^{tree}'), api.repo, pr, allow_open_automation=allow_open_automation)
    return record


def select_qualified_pr(api, sha, version, target_tree=None, native_directory=None):
    pulls = list(api.pages(f'commits/{sha}/pulls'))
    for candidate in pulls:
        pr = api.get(f"pulls/{candidate['number']}")
        if not (pr['merged'] and pr['merge_commit_sha'] == sha and pr['base']['ref'] == 'main'
                and pr['head'].get('repo') and pr['head']['repo']['full_name'] == api.repo):
            continue
        if pr['head'].get('ref', '').startswith('automation/upstream-'):
            identity = automated_pr_identity(pr)
            require(identity is not None, 'Merged automatic PR ownership is ambiguous')
            runs = (r for r in api.pages('actions/workflows/build-windows.yml/runs?event=workflow_dispatch&branch=main', 'workflow_runs')
                    if automated_run(r) == identity)
        else:
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
                    # Reject missing/stale native evidence before downloading the larger package.
                    raw = download_native(api, run, native_directory) if native_directory is not None else None
                    record = verify(api, run, artifact, version, Path(temporary), pr, target_tree=target_tree)
                except NotReusable as error:
                    summary(f'Fresh qualification required: {error}')
                    break
            return pr, run, artifact, record, raw
    return None


def plan():
    api = API()
    pin = json.loads(Path('upstream.json').read_text())
    version = pin_version(pin)
    values = dict(version=version, publish=False, reuse=False, artifact_id='', artifact_digest='', run_id='', source_commit='')
    inputs = dispatch_inputs() if os.environ['GITHUB_EVENT_NAME'] == 'workflow_dispatch' else {}
    automatic = any(inputs.get(key) for key in ('upstream_pr', 'expected_head', 'expected_base'))
    promotion = any(inputs.get(key) for key in ('qualified_run_id', 'qualified_artifact_id', 'qualified_artifact_digest', 'expected_merge'))
    require(not (automatic and promotion), 'Qualification and promotion inputs cannot be combined')
    if automatic:
        plan_automatic(api, inputs, values)
        return
    if promotion:
        pr, run, artifact, record = selected_promotion(api, inputs, version)
        values.update(publish=release_policy(api, version, resume=(record, artifact, os.environ['GITHUB_SHA'])), reuse=True, artifact_id=artifact['id'],
                      artifact_digest=artifact['digest'], run_id=run['id'], source_commit=record['sourceCommit'])
        summary(f"Promoting exact qualified run {run['id']} for merged PR #{pr['number']}; no repeated build or tests.")
        output(values)
        return
    component = os.environ.get('COMPONENT', '')
    if os.environ['GITHUB_EVENT_NAME'] == 'workflow_dispatch' and component not in ('', 'all'):
        output(values)
        return
    values['publish'] = release_policy(api, version)
    if os.environ['GITHUB_EVENT_NAME'] == 'push' and os.environ['GITHUB_REF'] == 'refs/heads/main':
        sha = os.environ['GITHUB_SHA']
        if not values['publish']:
            from publish_qualified import notes, published_metadata
            published, record, artifact, assets = published_metadata(api, version)
            if published['body'] != notes(record, artifact, record['mainCommit']) or any(a.get('label') for a in assets):
                values.update(publish=True, reuse=True, metadata_only=True, artifact_id=artifact['id'],
                              artifact_digest=artifact['digest'], run_id=record['runId'], source_commit=record['sourceCommit'])
                summary(f'Refreshing published {version} metadata through the existing publisher; no repeated build or artifact download.')
                output(values)
                return
        selected = select_qualified_pr(api, sha, version)
        if selected:
            pr, run, artifact, record, _ = selected
            values.update(reuse=True, artifact_id=artifact['id'], artifact_digest=artifact['digest'],
                          run_id=run['id'], source_commit=record['sourceCommit'])
            summary(f"Reusing qualified PR #{pr['number']} run {run['id']} attempt {run['run_attempt']}; identical Git tree {record['sourceTree']}. No repeated build or tests. Artifact {artifact['id']} ({artifact['digest']}).")
            output(values)
            return
    summary('No reusable qualification selected. Run the full build and test gate once.')
    output(values)


def native_artifact_for(api, run_id):
    artifacts = [a for a in api.pages(f'actions/runs/{run_id}/artifacts', 'artifacts')
                 if a['name'] == 'libvips' and not a['expired']]
    require(len(artifacts) <= 1, 'Ambiguous raw libvips artifacts')
    return artifacts[0] if artifacts else None


def validate_native_provenance(api, run, artifact):
    require(run['repository']['full_name'] == run['head_repository']['full_name'] == api.repo
            and run['status'] == 'completed' and run['conclusion'] == 'success'
            and (run['event'] == 'pull_request' or automated_run(run) is not None) and run['path'] == WORKFLOW,
            'Raw libvips source is not a successful same-repository PR qualification')
    provenance = artifact['workflow_run']
    require(provenance['id'] == run['id'] and provenance['head_sha'] == run['head_sha']
            and provenance['repository_id'] == provenance['head_repository_id']
            == run['repository']['id'] == run['head_repository']['id'],
            'Raw libvips artifact belongs to another run/head/repository')
    jobs = list(api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", 'jobs'))
    codec = [j for j in jobs if j['name'] == 'codec' and j['conclusion'] == 'success'
             and j['run_attempt'] == run['run_attempt']]
    if not codec:
        raise NotReusable('Raw libvips has no successful codec job in the current attempt')
    require(len(codec) == 1, 'Ambiguous current-attempt codec jobs')
    # Artifact records lack run_attempt. Bind creation to the actual codec job
    # rather than accepting a leftover artifact from an earlier attempt.
    created = datetime.fromisoformat(artifact['created_at'])
    if created < datetime.fromisoformat(codec[0]['started_at']):
        raise NotReusable('Raw libvips belongs to a previous codec attempt')
    require(created <= datetime.fromisoformat(codec[0]['completed_at']),
            'Raw libvips was created after the selected codec job')


def validate_native_bundle(archive, destination):
    root_files = {'immich-windows-libvips.json', 'versions.json', 'LICENSE', 'README.md', 'ChangeLog'}
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        names = [e.filename for e in entries]
        require(len(names) == len(set(n.casefold() for n in names)), 'Duplicate raw libvips entries')
        require({'immich-windows-libvips.json', 'lib/libvips-42.dll', 'lib/libglib-2.0-0.dll'} <= set(names),
                'Raw libvips bundle is incomplete')
        require(sum(e.file_size for e in entries) <= MAX_BYTES, 'Oversized raw libvips bundle')
        for entry in entries:
            name = entry.filename
            parts = name.rstrip('/').split('/')
            require(entry.orig_filename == name and not any(p in ('', '.', '..') for p in parts)
                    and ':' not in name and '\\' not in name
                    and not (entry.external_attr >> 16 & 0o170000 == 0o120000)
                    and (name in root_files or (parts[0] == 'lib' and
                         (entry.is_dir() or (len(parts) > 1 and name.endswith('.dll'))))),
                    'Unsafe or unexpected raw libvips entry')
        require(bundle.getinfo('immich-windows-libvips.json').file_size < 64 * 1024,
                'Oversized native build metadata')
        metadata = json.loads(bundle.read('immich-windows-libvips.json').decode('utf-8-sig'))
        require(metadata.get('schemaVersion') == 1, 'Invalid native build metadata schema')
        fields = ('nativeBuildInputsSha256', 'mediaPatchesSha256')
        require(all(re.fullmatch(r'[0-9a-f]{64}', metadata.get(field, '')) for field in fields),
                'Missing native build identity')
        expected = json.loads(subprocess.check_output([
            'pwsh', '-NoLogo', '-NoProfile', '-Command',
            'Import-Module ./build/NativeMediaValidation.psm1 -Force; '
            'Get-NativeMediaBuildIdentity -RepositoryRoot (Get-Location).Path | ConvertTo-Json -Compress'
        ], text=True, encoding='utf-8'))
        if any(metadata[field] != expected[field] for field in fields):
            raise NotReusable('Native inputs changed; build libvips from the current inputs')
        for entry in entries:
            if entry.is_dir():
                continue
            target = destination / entry.filename
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(entry) as source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
    subprocess.run([
        'pwsh', '-NoLogo', '-NoProfile', '-Command',
        'Import-Module ./build/NativeMediaValidation.psm1 -Force; '
        "Assert-WindowsPeTlsDirectory -Path (Join-Path $env:NATIVE_BUNDLE_ROOT 'lib/libglib-2.0-0.dll')"
    ], env=dict(os.environ, NATIVE_BUNDLE_ROOT=str(destination.resolve())), check=True)


def download_native(api, run, destination):
    artifact = native_artifact_for(api, run['id'])
    if artifact is None:
        raise NotReusable('Raw libvips artifact is missing or expired')
    validate_native_provenance(api, run, artifact)
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / 'libvips.zip'
        try:
            api.download(artifact, archive)
        except urllib.error.HTTPError as error:
            if error.code in (404, 410):
                raise NotReusable('Raw libvips artifact is no longer available') from error
            raise
        validate_native_bundle(archive, destination)
    return artifact


def prepare_native():
    api = API()
    destination = Path('artifacts/native/sharp-libvips-custom')
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
            bundle = Path(temporary) / 'bundle'
            selected_run = os.environ.get('QUALIFIED_RUN_ID')
            if selected_run:
                # These immutable identities come only from this workflow's plan job,
                # which already verified the complete merged tree and qualification.
                require(os.environ['GITHUB_EVENT_NAME'] in ('push', 'workflow_dispatch') and os.environ['GITHUB_REF'] == 'refs/heads/main',
                        'Selected qualification may seed only the main cache')
                run = api.get(f'actions/runs/{int(selected_run)}')
                qualified = artifacts_for(api, run['id'])
                require(len(qualified) == 1 and str(qualified[0]['id']) == os.environ['QUALIFIED_ARTIFACT_ID']
                        and qualified[0]['digest'] == os.environ['QUALIFIED_ARTIFACT_DIGEST'],
                        'Selected qualification artifact changed before cache seeding')
                artifact = download_native(api, run, bundle)
            else:
                event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
                if os.environ['GITHUB_EVENT_NAME'] == 'workflow_dispatch':
                    inputs = event.get('inputs', {})
                    number = positive_id(inputs.get('upstream_pr'), 'upstream PR')
                    pr, _ = automatic_candidate(api, number, inputs.get('expected_head', ''), inputs.get('expected_base', ''))
                    require(os.environ['GITHUB_REF'] == 'refs/heads/main' and os.environ['GITHUB_SHA'] == pr['base']['sha'],
                            'Native bootstrap dispatch has the wrong base')
                    base = pr['base']
                else:
                    require(os.environ['GITHUB_EVENT_NAME'] == 'pull_request', 'Native bootstrap requires a PR base')
                    base = event['pull_request']['base']
                require(base['ref'] == 'main' and SHA.fullmatch(base['sha']), 'Invalid native bootstrap base')
                source = api.get(f"git/commits/{base['sha']}")
                require(source['sha'] == base['sha'], 'Native bootstrap base identity mismatch')
                pin_file = api.get(f"contents/upstream.json?ref={base['sha']}")
                require(pin_file['encoding'] == 'base64', 'Invalid base version response')
                pin = json.loads(base64.b64decode(pin_file['content']))
                version = pin_version(pin)
                selected = select_qualified_pr(api, base['sha'], version, source['tree']['sha'], native_directory=bundle)
                if selected is None:
                    raise NotReusable('No qualified raw libvips artifact for this merged base')
                _, run, _, _, artifact = selected
            if destination.exists():
                shutil.rmtree(destination)
            bundle.rename(destination)
        output({'reused': True})
        summary(f"Reused raw libvips artifact {artifact['id']} from qualified run {run['id']}; current native inputs and PE TLS verified. No native rebuild.")
    except NotReusable as error:
        output({'reused': False})
        summary(f'Native cache not seeded: {error}')


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
            if current['merge_commit_sha'] == os.environ['GITHUB_SHA'] and (current['head']['sha'] == run['head_sha'] or automated_run(run) is not None and automated_run(run) == automated_pr_identity(current)):
                pr = current
                break
        require(pr is not None, 'Merged PR association disappeared')
    require(not same_run or run['head_sha'] == os.environ['GITHUB_SHA'], 'Publisher run is not the current main commit')
    record = verify(api, run, artifact, version, directory, pr, allow_original_attempt=same_run)
    if not same_run and (identity := automated_run(run)) is not None:
        latest, _ = automatic_candidate(api, *identity, merged=True)
        require(latest['merge_commit_sha'] == os.environ['GITHUB_SHA']
                and api.get('git/ref/heads/main')['object']['sha'] == os.environ['GITHUB_SHA'],
                'Automatic main changed before publication')
    output({'source_commit': record['sourceCommit'], 'source_tree': record['sourceTree'], 'run_id': source_run,
            'artifact_id': artifact['id'], 'artifact_digest': artifact['digest']})
    return record, artifact


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'record', 'prepare-publish', 'prepare-native', 'publish'])
    parser.add_argument('--version')
    parser.add_argument('--directory', type=Path, default=Path('dist'))
    args = parser.parse_args()
    if args.command == 'plan':
        plan()
    elif args.command == 'record':
        record_bundle(args.version, args.directory)
    elif args.command == 'prepare-native':
        prepare_native()
    elif args.command == 'publish':
        from publish_qualified import publish, refresh_published_metadata
        if os.environ.get('METADATA_ONLY') == 'true':
            refresh_published_metadata(API(), args.version, os.environ['GITHUB_SHA'])
        else:
            record, artifact = prepare_publish(args.version, args.directory)
            publish(API(), record, artifact, args.directory, os.environ['GITHUB_SHA'])
    else:
        prepare_publish(args.version, args.directory)
