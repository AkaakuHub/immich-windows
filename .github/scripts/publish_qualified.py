"""Publish or resume only evidence-bound, immutable qualified release assets."""
import json
from itertools import islice
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

from qualified_release import API, DIGEST, SHA, filenames, require, sha256, summary


def notes(record, artifact, commit):
    evidence = {'repository': record['repository'], 'version': record['version'],
                'mainCommit': commit, 'sourceCommit': record['sourceCommit'], 'sourceTree': record['sourceTree'],
                'runId': record['runId'], 'artifactId': artifact['id'], 'artifactDigest': artifact['digest'],
                'assets': record['assets']}
    return (f"Immich Windows {record['version']}. Release commit: {commit}. "
            f"Actual build commit: {record['sourceCommit']}. Source tree: {record['sourceTree']}. "
            f"Qualified run: https://github.com/{record['repository']}/actions/runs/{record['runId']}. "
            f"Artifact: {artifact['id']} ({artifact['digest']}). The tested assets are published byte-for-byte.\n\n"
            '<!-- immich-windows:qualified-release:v1 ' + json.dumps(evidence, sort_keys=True, separators=(',', ':')) + ' -->')


def asset_label(record, artifact, name):
    return f"qualified-run-{record['runId']}-artifact-{artifact['id']}-sha256-{record['assets'][name]}"


def validate_release(release, record, artifact, commit):
    require(release['tag_name'] == record['version'] and release['name'] == record['version']
            and release['target_commitish'] == commit and release['prerelease'] is False
            and release.get('author', {}).get('login') == 'github-actions[bot]'
            and release.get('body') == notes(record, artifact, commit),
            'Existing release/draft does not belong to this exact qualified artifact; refusing to modify it')


def validate_tag(api, version, commit, *, missing_allowed):
    try:
        ref = api.get(f'git/ref/tags/{version}')
    except urllib.error.HTTPError as error:
        if error.code == 404 and missing_allowed:
            return
        raise
    target = ref['object']
    for _ in range(5):
        require(SHA.fullmatch(target.get('sha', '')), 'Invalid release tag object')
        if target.get('type') == 'commit':
            require(target['sha'] == commit, 'Release tag points to another commit; refusing to overwrite it')
            return
        require(target.get('type') == 'tag', 'Unexpected release tag object type')
        target = api.get(f"git/tags/{target['sha']}")['object']
    raise ValueError('Excessively nested release tag')


def assets_state(api, release_id, record, artifact, directory):
    assets = list(api.pages(f'releases/{release_id}/assets'))
    expected = filenames(record['version'])
    require(len({a['name'] for a in assets}) == len(assets), 'Duplicate release assets')
    require(all(a['name'] in expected for a in assets), 'Unexpected release asset; refusing to modify this release')
    complete, starters = {}, {}
    for asset in assets:
        name = asset['name']
        if asset.get('state') == 'starter':
            require(asset['size'] == 0 and not asset.get('digest')
                    and asset.get('label') == asset_label(record, artifact, name)
                    and asset.get('uploader', {}).get('login') == 'github-actions[bot]',
                    'Unowned or nonempty incomplete release asset; refusing to delete it')
            starters[name] = asset
        else:
            require(asset.get('state') == 'uploaded' and asset.get('digest') == 'sha256:' + record['assets'][name]
                    and asset['size'] == (directory / name).stat().st_size,
                    f'Existing completed asset differs from qualification: {name}; never overwrite it')
            complete[name] = asset
    return complete, starters


def upload(api, release_id, path, label):
    # Fixed GitHub upload host, never an externally supplied upload_url. Stream
    # exact verified bytes and never forward the credential through redirects.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    request = api.request('')
    request.full_url = (f'https://uploads.github.com/repos/{api.repo}/releases/{release_id}/assets?'
                        + urllib.parse.urlencode({'name': path.name, 'label': label}))
    request.method = 'POST'
    request.add_header('Content-Type', 'application/octet-stream')
    with path.open('rb') as stream:
        request.data = iter(lambda: stream.read(1024 * 1024), b'')
        request.add_header('Content-Length', str(path.stat().st_size))
        with urllib.request.build_opener(NoRedirect).open(request, timeout=300) as response:
            return json.load(response)


def publish(api, record, artifact, directory, commit):
    version = record['version']
    require(SHA.fullmatch(commit) and DIGEST.fullmatch(artifact['digest']), 'Invalid publication identity')
    require(api.get('git/ref/heads/main')['object']['sha'] == commit, 'Main changed before release publication')
    expected = filenames(version)
    require(set(record['assets']) == expected, 'Unexpected qualified asset manifest')
    for name in expected:
        require(sha256(directory / name) == record['assets'][name], 'Prepared asset changed before publication')
    # One recent page only. Exact current-tag lookup can include an older
    # published release; never traverse historical releases to find a draft.
    recent = list(islice(api.pages('releases'), 100))
    matches = [r for r in recent if r['tag_name'] == version]
    if not matches:
        try:
            exact = api.get(f'releases/tags/{version}')
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            require(len(recent) < 100, 'Current draft identity is outside the bounded lookup; refusing to create a duplicate')
        else:
            require(exact['tag_name'] == version, 'Unexpected release tag lookup')
            matches = [exact]
    require(len(matches) <= 1, 'Ambiguous releases for this version')
    validate_tag(api, version, commit, missing_allowed=not matches or matches[0]['draft'])
    if matches:
        release = matches[0]
        validate_release(release, record, artifact, commit)
    else:
        release = api.write('releases', {'tag_name': version, 'target_commitish': commit, 'name': version,
                            'body': notes(record, artifact, commit), 'draft': True, 'prerelease': False})
        validate_release(release, record, artifact, commit)
    release_id = release['id']
    complete, starters = assets_state(api, release_id, record, artifact, directory)
    if not release['draft']:
        require(set(complete) == expected and not starters, 'Published release is incomplete; never modify a published release')
        summary(f'{version} is already published with these exact qualified bytes; no change.')
        return
    # Validate ALL present assets before the first mutation. A 502 may leave an
    # empty starter record; only our exact run/digest label permits its removal.
    for starter in starters.values():
        api.write(f"releases/assets/{starter['id']}", None, method='DELETE')
    for name in sorted(expected - complete.keys()):
        try:
            upload(api, release_id, directory / name, asset_label(record, artifact, name))
        except (urllib.error.URLError, TimeoutError, OSError):
            # An accepted upload can lose its response. Establish its state once,
            # without blindly repeating the write; otherwise leave daily recovery.
            present, _ = assets_state(api, release_id, record, artifact, directory)
            if name not in present:
                raise
    complete, starters = assets_state(api, release_id, record, artifact, directory)
    require(set(complete) == expected and not starters, 'Not every qualified asset uploaded successfully')
    latest = api.get(f'releases/{release_id}')
    validate_release(latest, record, artifact, commit)
    validate_tag(api, version, commit, missing_allowed=latest['draft'])
    require(api.get('git/ref/heads/main')['object']['sha'] == commit, 'Main changed before final publication')
    if latest['draft']:
        result = api.write(f'releases/{release_id}', {'draft': False, 'make_latest': 'true'}, method='PATCH')
        validate_release(result, record, artifact, commit)
        require(result['draft'] is False, 'Release publication was not confirmed')
    validate_tag(api, version, commit, missing_allowed=False)
    summary(f'Published {version} from verified artifact {artifact["id"]}; no rebuilding, repacking or asset overwrites.')
