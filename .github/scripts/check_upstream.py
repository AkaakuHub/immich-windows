"""Daily stable-release detection and idempotent, Git-Data-API-only PR preparation.

This entry point never builds, merges, or publishes. It dispatches the existing
qualification workflow once per exact same-repository update head; qualification
and publication retain their own independent evidence gates.
"""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

UPSTREAM = 'immich-app/immich'
WORKFLOW = 'build-windows.yml'
BRANCH_PREFIX = 'automation/upstream-'
PATCH_ROOTS = ('patches', 'metadata-patches')
STABLE = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')
SHA = re.compile(r'[0-9a-f]{40}')
MARKER = '<!-- immich-windows:automatic-upstream:v1 -->'
QUALIFICATION_TITLE = re.compile(r'Qualify upstream PR #[1-9][0-9]* head=[0-9a-f]{40} base=[0-9a-f]{40}')
OWNERSHIP = re.compile(r'<!-- immich-windows:automatic-head ([0-9a-f]{40}) base ([0-9a-f]{40}) -->')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(version):
    require(isinstance(version, str) and STABLE.fullmatch(version), f'Invalid stable version: {version!r}')
    return tuple(map(int, version[1:].split('.')))


def summary(message):
    print(message)
    if target := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(target, 'a', encoding='utf-8') as stream:
            stream.write(message + '\n')


class GitHub:
    def __init__(self, repo=None):
        self.repo = repo or os.environ['GITHUB_REPOSITORY']
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', self.repo), 'Invalid repository')

    def request(self, method, path, data=None, repo=None):
        repository = repo or self.repo
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository), 'Invalid repository')
        require(not path.startswith('/') and '://' not in path, 'Invalid API path')
        # The credential is scoped to GitHub; refuse redirects rather than risk
        # transmitting it to an untrusted asset or following a repository rename.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        body = None if data is None else json.dumps(data).encode('utf-8')
        request = urllib.request.Request(f'https://api.github.com/repos/{repository}/{path}', body, {
            'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
            'Accept': 'application/vnd.github+json',
            'Content-Type': 'application/json',
            'X-GitHub-Api-Version': '2022-11-28',
        }, method=method)
        with urllib.request.build_opener(NoRedirect).open(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else None

    def get(self, path, repo=None):
        return self.request('GET', path, repo=repo)

    def write(self, method, path, data):
        return self.request(method, path, data)

    def pages(self, path, key=None):
        page = 1
        while True:
            data = self.get(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
            items = data[key] if key else data
            yield from items
            if len(items) < 100:
                return
            page += 1

    def file(self, path, ref, repo=None):
        response = self.get('contents/' + urllib.parse.quote(path, safe='/') + '?ref=' + urllib.parse.quote(ref, safe=''), repo)
        require(response.get('encoding') == 'base64' and response.get('type') == 'file', f'Invalid file response: {path}')
        return base64.b64decode(response['content'], validate=False).decode('utf-8')


def resolve_commit(api, tag):
    value = api.get('git/ref/tags/' + tag, UPSTREAM)['object']
    for _ in range(5):
        require(SHA.fullmatch(value.get('sha', '')), 'Invalid upstream tag Git object')
        if value.get('type') == 'commit':
            return value['sha']
        require(value.get('type') == 'tag', 'Upstream tag does not resolve to a commit')
        value = api.get('git/tags/' + value['sha'], UPSTREAM)['object']
    raise ValueError('Upstream tag nesting is excessive')


def validate_pr(api, pr, branch, version, upstream_commit):
    require(pr['base']['ref'] == 'main' and pr['base']['repo']['full_name'] == api.repo
            and pr['head'].get('repo') and pr['head']['repo']['full_name'] == api.repo
            and pr['head']['ref'] == branch, 'Update PR repository/branch identity changed')
    require(pr.get('user', {}).get('login') == 'github-actions[bot]', 'Automatic PR was not created by the repository workflow')
    require(MARKER in (pr.get('body') or ''), 'An unrelated PR uses the automatic update branch; inspect it manually')
    head = pr['head']['sha']
    require(SHA.fullmatch(head), 'Invalid update PR head')
    owner = OWNERSHIP.findall(pr.get('body') or '')
    require(len(owner) == 1 and owner[0][0] == head, 'Automatic PR head changed outside this workflow; refusing to overwrite it')
    pin = json.loads(api.file('upstream.json', head))
    require(pin['version'] == version and pin['commit'] == upstream_commit and type(pin.get('windowsRevision')) is int
            and pin['windowsRevision'] == 0, 'Existing automatic PR does not contain the expected upstream revision zero')


def merge_metadata_ready(api, pr):
    """GitHub may not have computed a brand-new PR merge ref yet."""
    for attempt in range(3):
        fresh = api.get(f"pulls/{pr['number']}")
        require(fresh['head']['sha'] == pr['head']['sha'] and fresh['base']['sha'] == pr['base']['sha']
                and fresh['state'] == 'open', 'PR changed before qualification dispatch')
        require(fresh.get('mergeable') is not False, 'Automatic update has a merge conflict; qualification was not started')
        merge = fresh.get('merge_commit_sha') or ''
        if SHA.fullmatch(merge):
            try:
                source = api.get('git/commits/' + merge)
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
            else:
                if fresh.get('mergeable') is True and source['sha'] == merge and [parent['sha'] for parent in source['parents']] == [pr['base']['sha'], pr['head']['sha']]:
                    return True
        if attempt < 2:
            time.sleep(2)
    summary(f"PR #{pr['number']} merge metadata is not ready; no build was started. The next daily/manual check will resume.")
    return False


def dispatch_once(api, pr, recover_completion=None):
    head = pr['head']['sha']
    require(OWNERSHIP.findall(pr.get('body') or '') == [(head, pr['base']['sha'])], 'Main changed after update preparation; wait for a refreshed qualification')
    title = f"Qualify upstream PR #{pr['number']} head={head} base={pr['base']['sha']}"
    runs = api.pages(f'actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch', 'workflow_runs')
    # A failed qualification is evidence of a real blocker, not permission to
    # burn runner time by repeating the same build every day.
    run = next((run for run in runs if run.get('event') == 'workflow_dispatch' and run.get('display_title') == title
                and run.get('head_repository', {}).get('full_name') == api.repo), None)
    if run:
        if run['status'] == 'completed' and run.get('conclusion') == 'success' and recover_completion is not None:
            if recover_completion(run['id']):
                return 'completion-recovery'
        summary(f"PR #{pr['number']} already has qualification run {run['id']} ({run['status']}/{run.get('conclusion')}); no duplicate build.")
        return 'existing-run'
    if not merge_metadata_ready(api, pr):
        return 'awaiting-merge-metadata'
    api.write('POST', f'actions/workflows/{WORKFLOW}/dispatches', {
        'ref': 'main',
        'inputs': {'component': 'all', 'upstream_pr': str(pr['number']), 'expected_head': head,
                   'expected_base': pr['base']['sha']},
    })
    summary(f"Queued one qualification for PR #{pr['number']} at {head}. Tests must succeed before merge and publication.")
    return 'dispatched'


def prepare_patches(api, main, old_commit, new_commit):
    """Rebase only the recorded patch stack, with Git's conflict-free mechanics.

    API reads are pinned to immutable commits. No upstream hook or program is
    executed; only a minimal text-file Git repository exists in a disposable dir.
    """
    # Match Prepare-Source: Windows portability first, metadata behavior second.
    # One ordered worktree pair also handles patches that touch the same file.
    series_by_root, patches, paths = {}, {}, set()
    for root in PATCH_ROOTS:
        series_text = api.file(root + '/series', main)
        series = [line.strip() for line in series_text.splitlines() if line.strip() and not line.lstrip().startswith('#')]
        require(len(series) == len(set(series)), f'Duplicate entries in {root}/series')
        series_by_root[root] = (series_text, series)
        for name in series:
            require(name.endswith('.patch') and all(part not in ('', '.', '..', '.git') for part in name.split('/'))
                    and '\\' not in name and ':' not in name,
                    f'Unsafe patch-series entry in {root}/series')
            require(root != 'metadata-patches' or name.startswith('server/'),
                    'Metadata patches must be in metadata-patches/server')
            patch_path = root + '/' + name
            patch = api.file(patch_path, main)
            targets = re.findall(r'^\+\+\+ b/(.+)$', patch, re.M)
            require(targets and not re.search(r'^(rename |copy |GIT binary patch|deleted file mode|new file mode)', patch, re.M),
                    f'Patch {patch_path} uses an unsupported structural operation; manual review required')
            for path in targets:
                allowed = ('server/',) if root == 'metadata-patches' else ('server/', 'machine-learning/')
                require(path.startswith(allowed) and all(part not in ('', '.', '..', '.git') for part in path.split('/'))
                        and '\\' not in path and '\t' not in path and ':' not in path,
                        f'Unsafe target in patch {patch_path}')
                paths.add(path)
            patches[patch_path] = patch

    def command(directory, *arguments, check=True, data=None):
        # Blob stdin must bypass Windows text-mode newline conversion. Keep the
        # output interface textual for callers that inspect hashes and patches.
        result = subprocess.run(['git', '-C', str(directory), *arguments], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                                         GIT_ATTR_NOSYSTEM='1'))
        result.stdout = result.stdout.decode('utf-8')
        result.stderr = result.stderr.decode('utf-8', errors='replace')
        if check and result.returncode:
            raise ValueError(f"Patch preparation Git command failed: {' '.join(arguments)}\n{result.stderr.strip()}")
        return result

    changed, kept = {}, []
    with tempfile.TemporaryDirectory(prefix='immich-upstream-patches-') as temporary:
        old, new = Path(temporary) / 'old', Path(temporary) / 'new'
        for directory, commit in ((old, old_commit), (new, new_commit)):
            directory.mkdir()
            command(directory, 'init', '--quiet')
            for path in sorted(paths):
                target = directory / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(api.file(path, commit, UPSTREAM), encoding='utf-8', newline='')
            command(directory, 'add', '.')
        for name, patch in patches.items():
            patch_file = Path(temporary) / 'change.patch'
            patch_file.write_text(patch, encoding='utf-8', newline='')
            old_tree = command(old, 'write-tree').stdout.strip()
            old_bytes = {path: (old / path).read_bytes() for path in paths}
            command(old, 'apply', '--index', '--whitespace=error-all', str(patch_file))
            full_patch = command(old, 'diff', '--binary', '--full-index', old_tree).stdout
            require(full_patch, f'Empty patch: {name}')
            new_tree = command(new, 'write-tree').stdout.strip()
            direct = command(new, 'apply', '--check', '--index', '--whitespace=error-all', str(patch_file), check=False)
            if direct.returncode == 0:
                command(new, 'apply', '--index', '--whitespace=error-all', str(patch_file))
                kept.append(name)
                continue
            reverse = command(new, 'apply', '--reverse', '--check', '--index', str(patch_file), check=False)
            if reverse.returncode == 0:
                changed[name] = None
                summary(f'Upstream already contains {name}; removed the redundant patch.')
                continue
            # Supply exact old base blobs so --3way never fetches or guesses.
            for content in old_bytes.values():
                command(new, 'hash-object', '-w', '--stdin', data=content)
            patch_file.write_text(full_patch, encoding='utf-8', newline='')
            merged = command(new, 'apply', '--3way', '--index', '--whitespace=error-all', str(patch_file), check=False)
            if merged.returncode or command(new, 'ls-files', '--unmerged').stdout:
                raise ValueError(f'Cannot automatically apply patch {name} to {new_commit}:\n{merged.stderr.strip()}')
            rebased = command(new, 'diff', '--binary', '--full-index', new_tree).stdout
            if rebased:
                changed[name] = rebased
                kept.append(name)
                summary(f'Rebased {name} with a conflict-free Git three-way merge.')
            else:
                changed[name] = None
                summary(f'Upstream already implements {name}; removed the empty patch.')
    for root, (series_text, series) in series_by_root.items():
        removed = {name for name in series if root + '/' + name not in kept}
        if removed:
            changed[root + '/series'] = '\n'.join(line for line in series_text.splitlines() if line.strip() not in removed) + '\n'
    return changed


def write_tree(api, base, files):
    require(files and 'upstream.json' in files and 'dependencies/versions.json' in files, 'Updater omitted required version pins')
    entries = []
    # Validate the complete output before making any write, even orphan blobs.
    for path, content in sorted(files.items()):
        require(path in ('upstream.json', 'dependencies/versions.json', 'patches/series', 'metadata-patches/series')
                or path == 'media-patches/libvips/0001-put-other-loaders-ahead-of-dcrawload.patch'
                or (path.startswith(('patches/server/', 'patches/machine-learning/', 'metadata-patches/server/'))
                    and path.endswith('.patch')), f'Unexpected updater output: {path}')
        require(all(part not in ('', '.', '..', '.git') for part in path.split('/'))
                and '\\' not in path and ':' not in path, 'Invalid updater path')
        require(isinstance(content, str) or content is None, 'Updater output must be UTF-8 text or a deletion')
    for path, content in sorted(files.items()):
        if content is None:
            entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': None})
        else:
            blob = api.write('POST', 'git/blobs', {'content': content, 'encoding': 'utf-8'})
            entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
    return api.write('POST', 'git/trees', {'base_tree': base['tree']['sha'], 'tree': entries})['sha']


def write_branch(api, branch, base, files, version, previous_head=None):
    tree = write_tree(api, base, files)
    commit = api.write('POST', 'git/commits', {'message': f'chore: qualify Immich {version}.0 for Windows',
                                           'tree': tree, 'parents': [previous_head, base['sha']] if previous_head else [base['sha']]})
    # Never force-push or silently replace somebody else's existing update work.
    if previous_head:
        require(api.get('git/ref/heads/' + branch)['object']['sha'] == previous_head, 'Automatic branch changed during preparation')
        api.write('PATCH', 'git/refs/heads/' + branch, {'sha': commit['sha'], 'force': False})
    else:
        api.write('POST', 'git/refs', {'ref': 'refs/heads/' + branch, 'sha': commit['sha']})
    return commit['sha']


def run(api, prepare_update, recover_publication=None, recover_completion=None):
    main = api.get('git/ref/heads/main')['object']['sha']
    require(SHA.fullmatch(main), 'Invalid main revision')
    pin = json.loads(api.file('upstream.json', main))
    latest = api.get('releases/latest', UPSTREAM)
    version = latest.get('tag_name')
    require(latest.get('draft') is False and latest.get('prerelease') is False, 'Latest upstream release is not stable')
    current_number, latest_number = number(pin['version']), number(version)
    summary(f"Pinned: {pin['version']}.{pin['windowsRevision']}; latest stable: {version}.")
    if latest_number <= current_number:
        # A merged automatic update can outlive a transient publication failure.
        # Recover only its existing qualification; never start another build.
        if recover_publication is not None and recover_publication(main, pin):
            return 'publication-recovery'
        summary('No newer stable upstream release; no PR, build, or version change.')
        return 'unchanged'
    # One bounded read prevents parallel expensive version qualifications. An
    # existing failure never blocks a newer version indefinitely.
    recent = api.get(f'actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100')
    active = next((item for item in recent['workflow_runs']
                   if item.get('status') in ('queued', 'in_progress', 'waiting', 'pending', 'requested')
                   and item.get('head_repository', {}).get('full_name') == api.repo
                   and item.get('actor', {}).get('login') == 'github-actions[bot]'
                   and QUALIFICATION_TITLE.fullmatch(item.get('display_title', ''))), None)
    if active:
        summary(f"Automatic upstream qualification {active['id']} is still {active['status']}; defer the newer release until the next daily check.")
        return 'active-qualification'
    upstream_commit = resolve_commit(api, version)
    branch = BRANCH_PREFIX + version
    candidates = list(api.pages('pulls?state=all&base=main&head=' + urllib.parse.quote(api.repo.split('/')[0] + ':' + branch, safe='')))
    require(len(candidates) <= 1, 'Multiple PRs use the same automatic version branch; inspect them before continuing')
    if candidates:
        pr = api.get(f"pulls/{candidates[0]['number']}")
        if pr['state'] != 'open':
            summary(f"PR #{pr['number']} for {version} is already closed; no duplicate PR or build.")
            return 'closed'
        validate_pr(api, pr, branch, version, upstream_commit)
        recorded_base = OWNERSHIP.findall(pr['body'])[0][1]
        if recorded_base != main:
            dependencies = json.loads(api.file('dependencies/versions.json', main))
            files = prepare_update(api, pin, dependencies, dict(latest, commit=upstream_commit, windows_commit=main))
            files.update(prepare_patches(api, main, pin['commit'], upstream_commit))
            require(api.get('git/ref/heads/main')['object']['sha'] == main, 'Main changed during upstream preparation; run the check again')
            base = api.get('git/commits/' + main)
            head = write_branch(api, branch, base, files, version, previous_head=pr['head']['sha'])
            body = OWNERSHIP.sub(f'<!-- immich-windows:automatic-head {head} base {main} -->', pr['body'])
            api.write('PATCH', f"pulls/{pr['number']}", {'body': body})
            pr = api.get(f"pulls/{pr['number']}")
            validate_pr(api, pr, branch, version, upstream_commit)
            summary(f"Refreshed PR #{pr['number']} against current main; the new head requires fresh qualification.")
        return dispatch_once(api, pr, recover_completion)
    # Recover an interrupted run after branch creation but before PR creation.
    try:
        existing = api.get('git/ref/heads/' + branch)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        existing = None
    if existing is None:
        dependencies = json.loads(api.file('dependencies/versions.json', main))
        files = prepare_update(api, pin, dependencies, dict(latest, commit=upstream_commit, windows_commit=main))
        files.update(prepare_patches(api, main, pin['commit'], upstream_commit))
        # Refuse to build on a stale baseline when another change landed during
        # preflight. The next daily/manual check can prepare against current main.
        require(api.get('git/ref/heads/main')['object']['sha'] == main, 'Main changed during upstream preparation; run the check again')
        base = api.get('git/commits/' + main)
        head = write_branch(api, branch, base, files, version)
    else:
        head = existing['object']['sha']
        require(SHA.fullmatch(head), 'Invalid existing automatic branch head')
        candidate = json.loads(api.file('upstream.json', head))
        require(candidate['version'] == version and candidate['commit'] == upstream_commit
                and type(candidate.get('windowsRevision')) is int and candidate['windowsRevision'] == 0,
                'Existing branch has unexpected pins; refusing to replace it')
        commit = api.get('git/commits/' + head)
        require([parent['sha'] for parent in commit['parents']] == [main], 'Existing update branch is based on an older main; inspect it before continuing')
        dependencies = json.loads(api.file('dependencies/versions.json', main))
        files = prepare_update(api, pin, dependencies, dict(latest, commit=upstream_commit, windows_commit=main))
        files.update(prepare_patches(api, main, pin['commit'], upstream_commit))
        base = api.get('git/commits/' + main)
        expected_tree = write_tree(api, base, files)
        require(commit['tree']['sha'] == expected_tree, 'Unowned automatic branch differs from the deterministic update; refusing to adopt it')
        require(api.get('git/ref/heads/main')['object']['sha'] == main, 'Main changed during interrupted-run recovery')
    pr = api.write('POST', 'pulls', {
        'title': f'Update Immich to {version}.0', 'head': branch, 'base': 'main', 'draft': True,
        'body': f'{MARKER}\n<!-- immich-windows:automatic-head {head} base {main} -->\n\nAutomated stable update: {pin["version"]} → {version}.0.\n\n'
                f'Upstream commit: `{upstream_commit}`.\nUpstream release: https://github.com/{UPSTREAM}/releases/tag/{version}\n\n'
                'Version pins and the Windows and metadata patch stacks are prepared deterministically. '
                'Qualification must verify the exact PR head and current main before automatic merge; '
                'publication promotes the identical qualified artifacts without a second build.\n',
    })
    pr = api.get(f"pulls/{pr['number']}")
    require(pr['head']['sha'] == head, 'Update branch changed while creating PR')
    validate_pr(api, pr, branch, version, upstream_commit)
    return dispatch_once(api, pr, recover_completion)


if __name__ == '__main__':
    from upstream_pins import prepare_update
    from complete_upstream import recover_publication, recover_completion
    try:
        run(GitHub(), prepare_update, recover_publication, recover_completion)
    except urllib.error.HTTPError as error:
        detail = error.read(8192).decode('utf-8', errors='replace')
        try:
            detail = json.loads(detail).get('message', detail)
        except ValueError:
            pass
        message = f'GitHub API {error.code}: {detail}'
        if error.code in (401, 403):
            message += ' Check the workflow token permissions and whether Actions may create pull requests. No alternative token or permission change was attempted.'
        summary(message)
        raise SystemExit(1)
    except ValueError as error:
        summary(f'Upstream update stopped: {error}')
        raise SystemExit(1)
