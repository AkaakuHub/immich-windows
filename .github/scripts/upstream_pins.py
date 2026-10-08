"""Resolve stable upstream-owned runtime pins without changing Windows policy.

All source reads use dereferenced commit IDs. Unsupported layout/platform
mappings fail before any update is committed; native compatibility is still
proved by the Windows qualification workflow, never inferred from versions.
"""
from copy import deepcopy
import hashlib
import json
import re
import tomllib
from urllib.parse import quote

IMMICH = 'immich-app/immich'
BASE = 'immich-app/base-images'
MXE = 'libvips/build-win64-mxe'
PYTHON_STANDALONE = 'astral-sh/python-build-standalone'
PYTHON_ASSET = re.compile(
    r'cpython-(\d+\.\d+\.\d+)\+[^-]+-x86_64-pc-windows-msvc-install_only(?:_stripped)?\.tar\.gz')
SHA = re.compile(r'[0-9a-f]{40}')
VERSION = re.compile(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?')
WINDOWS_OWNED = ('postgresql', 'pgvector', 'vectorchord', 'valkey',
                 'onnxruntimeDirectml', 'uv', 'winsw')
LOADER = '0001-put-other-loaders-ahead-of-dcrawload.patch'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def unique(pattern, text, label):
    matches = re.findall(pattern, text, re.MULTILINE)
    require(len(matches) == 1, f'Cannot map {label}: expected one match, found {len(matches)}')
    return matches[0]


def tag_commit(api, repo, tag):
    """Support lightweight and nested annotated tags; reject cycles/noncommits."""
    item = api.get(f'git/ref/tags/{quote(tag, safe="")}', repo=repo)
    require(item.get('ref') == f'refs/tags/{tag}', f'Unexpected tag ref for {repo} {tag}')
    obj, seen = item['object'], set()
    for _ in range(8):
        require(SHA.fullmatch(obj.get('sha', '')), f'Invalid tag object for {repo} {tag}')
        if obj.get('type') == 'commit':
            return obj['sha']
        require(obj.get('type') == 'tag' and obj['sha'] not in seen, f'Invalid tag chain for {repo} {tag}')
        seen.add(obj['sha'])
        item = api.get(f"git/tags/{obj['sha']}", repo=repo)
        require(item.get('sha') == obj['sha'], 'Annotated tag identity mismatch')
        obj = item['object']
    raise ValueError(f'Tag chain too deep for {repo} {tag}')


def source(api, repo, ref, path):
    require(SHA.fullmatch(ref), 'Source reads must use immutable commits')
    return api.file(path, ref, repo=repo)


def update_dependency(result, name, source_url, version=None, **fields):
    """Apply one resolved dependency result through the common pin format."""
    value = result[name]
    if version is not None:
        fields['version'] = version
    fields['source'] = source_url
    value.update(fields)


def release_asset(api, repo, tag, name):
    release = api.get(f'releases/tags/{quote(tag, safe="")}', repo=repo)
    require(release.get('tag_name') == tag and not release.get('draft') and not release.get('prerelease'),
            f'Expected stable dependency release {repo} {tag}')
    assets = [asset for asset in release['assets'] if asset['name'] == name and asset.get('state', 'uploaded') == 'uploaded']
    require(len(assets) == 1, f'Missing or ambiguous Windows/source asset: {repo} {name}')
    checksum = assets[0].get('digest') or ''
    require(re.fullmatch(r'sha256:[0-9a-f]{64}', checksum), f'Missing SHA-256 for {repo} {name}')
    return checksum.removeprefix('sha256:')


def recipe_value(text, name):
    return unique(r'^\$\(PKG\)_' + name + r'\s*:=\s*(\S+)\s*$', text, f'MXE {name}')


def python_compatible(version, constraint):
    """Accept only deterministic simple numeric bounds; new syntax needs review."""
    current = tuple(map(int, version.split('.')))
    for bound in constraint.split(','):
        match = re.fullmatch(r'\s*(>=|<=|>|<|==)([0-9]+(?:\.[0-9]+){0,2})\s*', bound)
        require(match, f'Unsupported upstream Python constraint: {constraint}')
        other = tuple(map(int, match[2].split('.')))
        other += (0,) * (3 - len(other))
        passes = {'>=': current >= other, '<=': current <= other, '>': current > other,
                  '<': current < other, '==': current == other}[match[1]]
        if not passes:
            return False
    return True


def compatible_python_version(api, constraint):
    """Select the newest Windows CPython asset satisfying upstream's bounds."""
    release = api.get('releases/latest', repo=PYTHON_STANDALONE)
    candidates = []
    for asset in release.get('assets', []):
        name = asset.get('name', '')
        match = PYTHON_ASSET.fullmatch(name)
        if match and python_compatible(match[1], constraint):
            candidates.append(match[1])
    require(candidates, f'No Windows CPython runtime satisfies upstream {constraint}')
    lowest_supported_minor = min(tuple(map(int, value.split('.')[:2])) for value in candidates)
    return max(
        (value for value in candidates if tuple(map(int, value.split('.')[:2])) == lowest_supported_minor),
        key=lambda value: tuple(map(int, value.split('.'))),
    )


def prepare_update(api, current_pin, dependencies, release):
    """Return UTF-8 replacements, without mutating input or external state.

    api.get(path, repo=...) returns GitHub JSON; api.file(path, ref, repo=...)
    returns decoded UTF-8. A release may include the watcher's resolved commit.
    """
    version = release['tag_name']
    require(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', version) and not release.get('draft')
            and not release.get('prerelease'), 'Only stable upstream releases can be mapped')
    require(current_pin['repository'] == 'https://github.com/immich-app/immich.git', 'Unexpected upstream repository')
    require(dependencies['target'] == 'win-x64', 'Unsupported Windows dependency target')
    commit = tag_commit(api, IMMICH, version)
    require(not release.get('commit') or release['commit'] == commit, 'Upstream tag moved during update')
    files = {path: source(api, IMMICH, commit, path) for path in (
        'mise.toml', 'server/package.json', 'server/Dockerfile',
        'machine-learning/pyproject.toml', 'machine-learning/uv.lock')}
    mise = tomllib.loads(files['mise.toml'])['tools']
    server = json.loads(files['server/package.json'])
    ml = tomllib.loads(files['machine-learning/pyproject.toml'])['project']
    require('v' + server['version'] == version and 'v' + ml['version'] == version,
            'Upstream package versions do not match the release')
    python_version = dependencies['python']['version']
    if not python_compatible(python_version, ml['requires-python']):
        python_version = compatible_python_version(api, ml['requires-python'])
    providers = ml['optional-dependencies'].get('openvino', [])
    require(len(providers) == 1 and re.fullmatch(r'onnxruntime-openvino[><=0-9., ]+', providers[0]),
            'Upstream OpenVINO extra changed; review Windows DirectML replacement')
    lock = tomllib.loads(files['machine-learning/uv.lock'])
    require(any(item['name'] == 'onnxruntime-openvino' for item in lock['package']),
            'Upstream ML lock lacks the provider replaced by DirectML')

    image_pattern = r'^FROM ghcr\.io/immich-app/base-server-(dev|prod):([0-9]{12})@sha256:([0-9a-f]{64})(?: AS [A-Za-z0-9_-]+)?\s*$'
    images = re.findall(image_pattern, files['server/Dockerfile'], re.MULTILINE)
    require(len(images) == 2 and {x[0] for x in images} == {'dev', 'prod'}
            and images[0][1] == images[1][1], 'Cannot map upstream production base image')
    image = {kind: {'tag': tag, 'digest': checksum} for kind, tag, checksum in images}
    base_tag = image['prod']['tag']
    base_commit = tag_commit(api, BASE, base_tag)
    base_docker = source(api, BASE, base_commit, 'server/Dockerfile')
    node = unique(r'^FROM node:([0-9]+\.[0-9]+\.[0-9]+)-[^\s@]+@sha256:[0-9a-f]{64} AS prod\s*$',
                  base_docker, 'production Node')
    ffmpeg_source = json.loads(source(api, BASE, base_commit, 'server/packages/ffmpeg.json'))
    ffmpeg = ffmpeg_source['version']
    require(VERSION.fullmatch(ffmpeg), 'Unsupported production FFmpeg version')
    ffmpeg_asset = f'jellyfin-ffmpeg_{ffmpeg}_portable_win64-clang-gpl.zip'
    ffmpeg_checksum = release_asset(api, 'jellyfin/jellyfin-ffmpeg', f'v{ffmpeg}', ffmpeg_asset)
    result = deepcopy(dependencies)
    update_dependency(result, 'python', f'https://github.com/{PYTHON_STANDALONE}/releases/latest', python_version)
    provenance = f'https://github.com/{BASE}/blob/{base_commit}/'
    update_dependency(result, 'node', provenance + 'server/Dockerfile', node, asset=f'node-v{node}-win-x64.zip')
    update_dependency(result, 'ffmpeg', provenance + 'server/packages/ffmpeg.json', ffmpeg,
                      asset=ffmpeg_asset, sha256=ffmpeg_checksum)
    for local, upstream, prefix in [('pnpm', 'pnpm', ''), ('extismJs', 'github:extism/js-pdk', 'v'),
                                    ('binaryen', 'github:webassembly/binaryen', 'version_')]:
        value = mise[upstream]
        require(isinstance(value, str) and value.startswith(prefix), f'Unsupported mise pin: {upstream}')
        value = value[len(prefix):]
        require(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', value), f'Non-exact mise pin: {upstream}')
        update_dependency(result, local, f'https://github.com/{IMMICH}/blob/{commit}/mise.toml', value)
    result['extismJs']['asset'] = f"extism-js-x86_64-windows-v{result['extismJs']['version']}.gz"
    result['binaryen']['asset'] = f"binaryen-version_{result['binaryen']['version']}-x86_64-windows.tar.gz"
    sharp = server['dependencies']['sharp']
    require(re.fullmatch(r'[~^]?[0-9]+\.[0-9]+\.[0-9]+', sharp), 'Non-exact Sharp dependency baseline')
    update_dependency(result, 'sharp', f'https://github.com/{IMMICH}/blob/{commit}/server/package.json', sharp.lstrip('~^'))

    media_sources = {}
    expected_repositories = {'libvips': 'libvips/libvips', 'libheif': 'strukturag/libheif',
                             'libjxl': 'libjxl/libjxl', 'libraw': 'LibRaw/LibRaw', 'jpegli': 'google/jpegli'}
    for name, repo in expected_repositories.items():
        item = json.loads(source(api, BASE, base_commit, f'server/sources/{name}.json'))
        require(item['name'] == name and item['repository'] == repo and SHA.fullmatch(item['revision']),
                f'Unsupported production media source: {name}')
        media_sources[name] = item
    vips = media_sources['libvips']
    require(VERSION.fullmatch(vips['version']), 'Unsupported libvips version')
    require(tag_commit(api, 'libvips/libvips', 'v' + vips['version']) == vips['revision'],
            'Production libvips revision is not its version tag')
    mxe_tag = 'v' + vips['version']
    mxe_commit = tag_commit(api, MXE, mxe_tag)
    recipes = {name: source(api, MXE, mxe_commit, path) for name, path in {
        'vips': 'build/vips.mk', 'heif': 'build/libheif.mk', 'jxl': 'build/libjxl.mk',
        'jpegli': 'build/plugins/jpegli/jpegli.mk', 'overrides': 'build/overrides.mk'}.items()}
    require(recipe_value(recipes['vips'], 'VERSION') == vips['version'], 'MXE libvips recipe differs from production')
    require(tag_commit(api, 'libjxl/libjxl', 'v' + media_sources['libjxl']['version']) == media_sources['libjxl']['revision'],
            'Production JPEG XL revision is not its version tag')
    require(recipe_value(recipes['jxl'], 'VERSION') == media_sources['libjxl']['version'],
            'MXE JPEG XL differs from production; a Windows recipe update is required')
    require(media_sources['jpegli']['revision'].startswith(recipe_value(recipes['jpegli'], 'VERSION'))
            and len(recipe_value(recipes['jpegli'], 'VERSION')) >= 7
            and media_sources['jpegli']['revision'] in recipes['jpegli'],
            'MXE jpegli revision differs from production; a Windows recipe update is required')
    raw_version = unique(r'^libraw_VERSION\s*:=\s*(\S+)\s*$', recipes['overrides'], 'Windows LibRaw')
    require((raw_version == media_sources['libraw']['version'] and
             tag_commit(api, 'LibRaw/LibRaw', raw_version) == media_sources['libraw']['revision']) or
            (raw_version == '0.22.2' and media_sources['libraw']['version'] == '0.22.2-1'
             and media_sources['libraw']['revision'] == 'e419de08001de28ae6988ecb22df47e52b9c5eaa'),
            'Unmapped production LibRaw change; review the Windows override')
    loader_path = f'server/sources/libvips-patches/{LOADER}'
    patches = api.get(f'contents/server/sources/libvips-patches?ref={base_commit}', repo=BASE)
    require(len(patches) == 1 and patches[0]['path'] == loader_path and patches[0]['type'] == 'file',
            'Production libvips patch set changed; review Windows port')
    loader = source(api, BASE, base_commit, loader_path)
    heif = media_sources['libheif']
    require(VERSION.fullmatch(heif['version']) and
            tag_commit(api, 'strukturag/libheif', 'v' + heif['version']) == heif['revision'],
            'Production libheif revision is not its version tag')
    heif_asset = f"libheif-{heif['version']}.tar.gz"
    heif_checksum = release_asset(api, 'strukturag/libheif', 'v' + heif['version'], heif_asset)
    result['sharpLibvips'].update(version=vips['version'], tag=mxe_tag, commit=mxe_commit,
        libvipsRevision=vips['revision'], immichBaseImagesCommit=base_commit,
        libheif={'version': heif['version'], 'revision': heif['revision'], 'sha256': heif_checksum,
                 'recipeVersion': recipe_value(recipes['heif'], 'VERSION'),
                 'recipeSha256': digest(recipes['heif']), 'source': provenance + 'server/sources/libheif.json'},
        notes='Native Windows MXE media build with upstream libvips/libheif and loader patch. Windows platform recipes and HEVC/jpegli/JXL/RAW feature flags are preserved. Keep HEVC/GPL license notices with the package.')
    result['upstreamRuntime'] = {
        'schemaVersion': 1, 'immichCommit': commit,
        'baseImages': {'repository': BASE, 'tag': base_tag, 'commit': base_commit, 'images': image},
        'nodeVersion': node, 'ffmpegVersion': ffmpeg,
        'developmentTools': {'node': mise['node'], 'ffmpeg': mise['github:jellyfin/jellyfin-ffmpeg']['version']},
        'sourceSha256': {path: digest(text) for path, text in files.items()},
        'mediaSources': media_sources,
        'windowsOverrides': {
            'preservedComponents': list(WINDOWS_OWNED),
            'machineLearning': 'Export the immutable upstream uv.lock openvino extra; replace only onnxruntime-openvino with the independently pinned Windows DirectML package. Select the newest compatible Windows CPython runtime automatically and keep the uv pin.',
            'media': 'Keep the MXE Windows platform recipes, GLib TLS fix and codec feature flags. LibRaw 0.22.2 is a reviewed Windows override for upstream 0.22.2-1; other unmapped source drift fails closed.',
            'database': 'Windows PostgreSQL, pgvector and VectorChord are independently pinned and validated by the native build/upgrade gates.'}}
    require(all(result[name] == dependencies[name] for name in WINDOWS_OWNED), 'Windows-owned dependency changed')
    for flag in ('target', 'variant', 'hevc', 'jpeg', 'immichLoaderPatch', 'repository'):
        require(result['sharpLibvips'][flag] == dependencies['sharpLibvips'][flag], f'Windows codec policy changed: {flag}')
    pin = deepcopy(current_pin)
    pin.update(version=version, commit=commit, windowsRevision=0,
               notes=f'{version} stable source and upstream production runtime pins; initial Windows revision 0. Native compatibility requires the release qualification gates.')
    return {
        'upstream.json': json.dumps(pin, indent=2, ensure_ascii=False) + '\n',
        'dependencies/versions.json': json.dumps(result, indent=2, ensure_ascii=False) + '\n',
        dependencies['sharpLibvips']['immichLoaderPatch']: loader,
    }
