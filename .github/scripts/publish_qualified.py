"""Publish or resume only evidence-bound, immutable qualified release assets."""
import json
from itertools import islice
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

from qualified_release import API, ARTIFACT, DIGEST, REQUIRED_JOBS, SHA, WORKFLOW, filenames, record_filenames, release_policy, require, sha256, summary


def notes(record, artifact, commit, *, legacy=False):
    evidence = {'repository': record['repository'], 'version': record['version'],
                'mainCommit': commit, 'sourceCommit': record['sourceCommit'], 'sourceTree': record['sourceTree'],
                'runId': record['runId'], 'artifactId': artifact['id'], 'artifactDigest': artifact['digest'],
                'assets': record['assets']}
    if legacy:
        # Exact compatibility for drafts created before the display correction.
        description = (f"Immich Windows {record['version']}. Release commit: {commit}. "
            f"Actual build commit: {record['sourceCommit']}. Source tree: {record['sourceTree']}. "
            f"Qualified run: https://github.com/{record['repository']}/actions/runs/{record['runId']}. "
            f"Artifact: {artifact['id']} ({artifact['digest']}). The tested assets are published byte-for-byte.")
    else:
        docs = f"https://github.com/{record['repository']}/blob/{commit}/docs"
        upgrade_notice = ("旧版からの更新にも、保存済みの古いものではなく新しい `Install.cmd` が必要です。"
                          if record['version'] == 'v3.2.4.0' else '')
        description = (f"Immich Windows {record['version']}（Windows x64向け）\n\n"
            f"通常の導入・更新は、このReleaseの `Install.cmd` をダウンロードして実行してください。{upgrade_notice}必要な配布ファイルは自動取得されます。PowerShell 7とPostgreSQL 18 x64が必要です。\n\n"
            f"- `immich-windows-{record['version']}-win-x64.zip`：本体\n"
            "- `dependency-*`：必要な依存ファイルだけ自動取得します\n"
            f"- `immich-windows-{record['version']}-migration-tools.zip`：データ移行ツール\n\n"
            "GitHubの `Source code` は導入用ではありません。\n\n"
            f"[導入手順]({docs}/install.md) · [更新手順]({docs}/operations.md) · [移行手順]({docs}/migration.md)")
    return (description + '\n\n<!-- immich-windows:qualified-release:v1 '
            + json.dumps(evidence, sort_keys=True, separators=(',', ':')) + ' -->')


def asset_label(record, artifact, name):
    return f"qualified-run-{record['runId']}-artifact-{artifact['id']}-sha256-{record['assets'][name]}"


def validate_release(release, record, artifact, commit):
    require(release['tag_name'] == record['version'] and release['name'] == record['version']
            and release['target_commitish'] == commit and release['prerelease'] is False
            and release.get('author', {}).get('login') == 'github-actions[bot]'
            and release.get('body') in (notes(record, artifact, commit), notes(record, artifact, commit, legacy=True)),
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


def published_metadata(api, version):
    """Validate already-public metadata only; never download or requalify bytes."""
    release = api.get(f'releases/tags/{version}')
    marker = '<!-- immich-windows:qualified-release:v1 '
    body = release.get('body') or ''
    require(not release['draft'] and body.count(marker) == 1 and body.endswith(' -->'),
            'Published release has no unambiguous qualified metadata')
    record = json.loads(body.split(marker)[1][:-4])
    require(record['repository'] == api.repo and record['version'] == version
            and SHA.fullmatch(record['mainCommit']) and SHA.fullmatch(record['sourceCommit'])
            and SHA.fullmatch(record['sourceTree']) and DIGEST.fullmatch(record['artifactDigest'])
            and set(record['assets']) == record_filenames(record), 'Invalid published qualification identity')
    artifact = api.get(f"actions/artifacts/{record['artifactId']}")
    require(artifact['id'] == record['artifactId'] and artifact['name'] == ARTIFACT
            and artifact['digest'] == record['artifactDigest'], 'Published artifact identity changed')
    validate_release(release, record, artifact, record['mainCommit'])
    validate_tag(api, version, record['mainCommit'], missing_allowed=False)
    source = api.get(f"git/commits/{record['sourceCommit']}")
    merged = api.get(f"git/commits/{record['mainCommit']}")
    require(source['sha'] == record['sourceCommit'] and merged['sha'] == record['mainCommit']
            and source['tree']['sha'] == merged['tree']['sha'] == record['sourceTree'],
            'Published source or release tree changed')
    run = api.get(f"actions/runs/{record['runId']}")
    require(run['id'] == record['runId'] and run['path'] == WORKFLOW and run['status'] == 'completed'
            and run['conclusion'] == 'success' and run['repository']['full_name'] == api.repo
            and run['head_repository']['full_name'] == api.repo
            and artifact['workflow_run']['id'] == run['id'] and artifact['workflow_run']['head_sha'] == run['head_sha']
            and artifact['workflow_run']['repository_id'] == artifact['workflow_run']['head_repository_id']
                == run['repository']['id'] == run['head_repository']['id'], 'Published run provenance changed')
    jobs = list(api.pages(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", 'jobs'))
    require(REQUIRED_JOBS <= {j['name'] for j in jobs if j['conclusion'] == 'success' and j['run_attempt'] == run['run_attempt']},
            'Published qualification jobs did not succeed')
    assets = list(api.pages(f"releases/{release['id']}/assets"))
    require(len(assets) == len(record['assets']) and len({a['id'] for a in assets}) == len(assets)
            and {a['name'] for a in assets} == record_filenames(record), 'Published asset set changed')
    for asset in assets:
        require(asset['state'] == 'uploaded' and asset['size'] > 0
                and asset['digest'] == 'sha256:' + record['assets'][asset['name']]
                and asset.get('label') in (None, '', asset_label(record, artifact, asset['name'])),
                'Published asset content or label changed')
    return release, record, artifact, assets


def refresh_published_metadata(api, version, commit):
    require(os.environ['GITHUB_EVENT_NAME'] == 'push' and os.environ['GITHUB_REF'] == 'refs/heads/main'
            and api.get('git/ref/heads/main')['object']['sha'] == commit, 'Metadata update must target current main')
    require(release_policy(api, version) is False, 'Metadata update requires an unchanged published payload')
    release, record, artifact, assets = published_metadata(api, version)
    require(str(record['runId']) == os.environ['QUALIFIED_RUN_ID']
            and str(artifact['id']) == os.environ['QUALIFIED_ARTIFACT_ID']
            and artifact['digest'] == os.environ['QUALIFIED_ARTIFACT_DIGEST'], 'Selected metadata evidence changed')
    # IDs, filenames and content metadata are snapshots, never PATCH payloads.
    fields = ('id', 'name', 'state', 'size', 'digest')
    before = {a['id']: {key: a[key] for key in fields} for a in assets}
    for asset in assets:
        if asset.get('label'):
            updated = api.write(f"releases/assets/{asset['id']}", {'label': ''}, method='PATCH')
            require(not updated.get('label') and all(updated.get(k) == v for k, v in before[asset['id']].items()),
                    'Published asset identity changed during display correction')
    body = notes(record, artifact, record['mainCommit'])
    if release['body'] != body:
        api.write(f"releases/{release['id']}", {'body': body}, method='PATCH')
    final, _, _, final_assets = published_metadata(api, version)
    require(final['id'] == release['id'] and final['body'] == body
            and {a['id']: {key: a[key] for key in fields} for a in final_assets} == before
            and all(not a.get('label') for a in final_assets), 'Release display correction was not confirmed')
    summary(f'Updated {version} description and labels only; no build, download, upload, rename or tag change.')


def assets_state(api, release_id, record, artifact, directory):
    assets = list(api.pages(f'releases/{release_id}/assets'))
    expected = record_filenames(record)
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
    expected = record_filenames(record)
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
        # Keep ownership labels on incomplete uploads. Only fully verified assets
        # lose the label, so GitHub displays their real filenames at publication.
        for name, asset in sorted(complete.items()):
            if asset.get('label'):
                updated = api.write(f"releases/assets/{asset['id']}", {'label': ''}, method='PATCH')
                require(not updated.get('label') and all(updated.get(key) == asset[key]
                        for key in ('id', 'name', 'state', 'size', 'digest')),
                        f'Asset display update changed its qualified identity: {name}')
        result = api.write(f'releases/{release_id}', {'body': notes(record, artifact, commit), 'draft': False, 'make_latest': 'true'}, method='PATCH')
        validate_release(result, record, artifact, commit)
        require(result['draft'] is False and result['body'] == notes(record, artifact, commit), 'Release publication was not confirmed')
    validate_tag(api, version, commit, missing_allowed=False)
    summary(f'Published {version} from verified artifact {artifact["id"]}; no rebuilding, repacking or asset overwrites.')
