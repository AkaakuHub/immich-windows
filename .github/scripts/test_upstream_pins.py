import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import upstream_pins as pins


class FakeAPI:
    def __init__(self):
        self.repo = 'example/windows'
        self.refs = {
            (pins.IMMICH, 'v3.2.4'): 'a' * 40,
            (pins.BASE, '202609281550'): 'b' * 40,
            (pins.MXE, 'v8.18.5'): 'c' * 40,
            ('libvips/libvips', 'v8.18.5'): 'd' * 40,
            ('strukturag/libheif', 'v1.23.3'): 'e' * 40,
            ('libjxl/libjxl', 'v0.12.0'): 'f' * 40,
            ('pgvector/pgvector', 'v0.8.5'): '6' * 40,
            ('supervc-stack/VectorChord', '1.1.1'): '7' * 40,
        }
        self.files = {
            (pins.IMMICH, 'mise.toml'): '[tools]\nnode="24.15.0"\npnpm="11.22.0"\n"github:extism/js-pdk"="v1.7.0"\n"github:webassembly/binaryen"="version_124"\n[tools."github:jellyfin/jellyfin-ffmpeg"]\nversion="7.1.3-6"\n',
            (pins.IMMICH, 'server/package.json'): json.dumps({'version': '3.2.4', 'dependencies': {'sharp': '^0.35.3'}}),
            (pins.IMMICH, 'server/Dockerfile'): f'FROM ghcr.io/immich-app/base-server-dev:202609281550@sha256:{"1" * 64} AS builder\nFROM ghcr.io/immich-app/base-server-prod:202609281550@sha256:{"2" * 64}\n',
            (pins.IMMICH, 'machine-learning/pyproject.toml'): '[project]\nversion="3.2.4"\nrequires-python=">=3.11,<4.0"\n[project.optional-dependencies]\nopenvino=["onnxruntime-openvino>=1.24.1,<2"]\n',
            (pins.IMMICH, 'machine-learning/Dockerfile'): 'FROM python:3.12-slim AS builder-openvino\n',
            (pins.IMMICH, 'machine-learning/uv.lock'): '[[package]]\nname="onnxruntime-openvino"\nversion="1.24.1"\n',
            (pins.BASE, 'server/Dockerfile'): f'FROM node:24.21.0-trixie-slim@sha256:{"3" * 64} AS prod\n',
            (pins.BASE, 'postgres/versions.yaml'): 'pg:\n  - "18"\nvectorchord:\n  - "1.1.1"\npgvector:\n  - "0.8.5"\n',
            (pins.BASE, 'server/packages/ffmpeg.json'): '{"version":"7.1.4-3"}',
            (pins.MXE, 'build/vips.mk'): '$(PKG)_VERSION := 8.18.5\n',
            (pins.MXE, 'build/libheif.mk'): f'$(PKG)_VERSION := 1.23.1\n$(PKG)_CHECKSUM := {"4" * 64}\n',
            (pins.MXE, 'build/libjxl.mk'): '$(PKG)_VERSION := 0.12.0\n',
            (pins.MXE, 'build/plugins/jpegli/jpegli.mk'): '# google/jpegli/tarball/' + 'f' * 40 + '\n$(PKG)_VERSION := ' + 'f' * 7 + '\n',
            (pins.MXE, 'build/overrides.mk'): 'libraw_VERSION := 0.22.2\n',
            (pins.BASE, f'server/sources/libvips-patches/{pins.LOADER}'): 'fixture loader patch\n',
        }
        for name, repo, version, revision in (
            ('libvips', 'libvips/libvips', '8.18.5', 'd' * 40),
            ('libheif', 'strukturag/libheif', '1.23.3', 'e' * 40),
            ('libjxl', 'libjxl/libjxl', '0.12.0', 'f' * 40),
            ('jpegli', 'google/jpegli', None, 'f' * 40),
            ('libraw', 'LibRaw/LibRaw', '0.22.2-1', 'e419de08001de28ae6988ecb22df47e52b9c5eaa'),
        ):
            value = dict(name=name, repository=repo, revision=revision)
            if version:
                value['version'] = version
            self.files[pins.BASE, f'server/sources/{name}.json'] = json.dumps(value)
        self.assets = {
            'jellyfin/jellyfin-ffmpeg': ('v7.1.4-3', 'jellyfin-ffmpeg_7.1.4-3_portable_win64-clang-gpl.zip'),
            'strukturag/libheif': ('v1.23.3', 'libheif-1.23.3.tar.gz'),
        }
        self.python_release = {
            'assets': [{'name': 'cpython-3.12.15+20261003-x86_64-pc-windows-msvc-install_only.tar.gz'}]
        }
        self.release_versions = {
            'astral-sh/uv': ('0.12.23', 'uv-x86_64-pc-windows-msvc.zip'),
            'valkey-windows/valkey-windows': ('9.1.2', 'Valkey-9.1.2-Windows-x64-msys2-with-Service.zip'),
            'winsw/winsw': ('2.12.0', 'WinSW-x64.exe'),
        }
        self.extra_patch = False
        self.asset_digest = 'sha256:' + '5' * 64
        self.calls = []
        self.annotated = {}

    def get(self, path, repo=None):
        self.calls.append((repo, path))
        if path.startswith('git/ref/tags/'):
            tag = path.removeprefix('git/ref/tags/')
            obj = self.annotated.get((repo, tag), {'type': 'commit', 'sha': self.refs[repo, tag]})
            return {'ref': f'refs/tags/{tag}', 'object': obj}
        if path.startswith('git/tags/'):
            sha = path.removeprefix('git/tags/')
            return self.annotated[sha]
        if path.startswith('releases/tags/'):
            tag, name = self.assets[repo]
            return {'tag_name': tag, 'draft': False, 'prerelease': False,
                    'assets': [{'name': name, 'digest': self.asset_digest}]}
        if path == 'releases/latest' and repo == pins.PYTHON_STANDALONE:
            return self.python_release
        if path == 'releases/latest' and repo in self.release_versions:
            version, asset = self.release_versions[repo]
            return {'tag_name': version, 'assets': [{'name': asset}]}
        if path.startswith('contents/'):
            patches = [{'path': f'server/sources/libvips-patches/{pins.LOADER}', 'type': 'file'}]
            return patches + ([{'path': 'new.patch', 'type': 'file'}] if self.extra_patch else [])
        raise AssertionError((repo, path))

    def file(self, path, ref, repo=None):
        if repo == 'supervc-stack/VectorChord':
            assert ref == '7' * 40
            return '[dependencies]\npgrx={version="=0.17.0"}\n'
        expected = {pins.IMMICH: 'a' * 40, pins.BASE: 'b' * 40, pins.MXE: 'c' * 40}[repo]
        assert ref == expected, (repo, path, ref)
        return self.files[repo, path]


class PinTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.current = {'repository': 'https://github.com/immich-app/immich.git', 'version': 'v3.2.2',
                        'commit': '0' * 40, 'windowsRevision': 9, 'buildArchitecture': 'win-x64'}
        self.dependencies = {'schemaVersion': 1, 'target': 'win-x64'}
        self.dependencies.update({name: {'version': '1.0.0'} for name in pins.WINDOWS_PRESERVED})
        self.dependencies.update({name: {'version': '1.0.0'} for name in ('pgvector', 'vectorchord', 'valkey', 'uv', 'winsw')})
        self.dependencies['python'] = {'version': '3.11.14'}
        self.dependencies['onnxruntimeDirectml']['version'] = '1.24.4'
        self.dependencies.update({name: {'version': '0.0.0'} for name in ('node', 'ffmpeg', 'pnpm', 'extismJs', 'binaryen', 'sharp')})
        self.dependencies['sharpLibvips'] = {'version': '8.18.5', 'target': 'x86_64-w64-mingw32.shared',
            'variant': 'vips-all', 'hevc': True, 'jpeg': 'jpegli', 'repository': 'https://github.com/libvips/build-win64-mxe.git',
            'immichLoaderPatch': 'media-patches/libvips/' + pins.LOADER}
        self.release = {'tag_name': 'v3.2.4', 'commit': 'a' * 40}

    def prepare(self):
        with patch.object(Path, 'read_text', return_value='fixture loader patch\n'):
            result = pins.prepare_update(self.api, self.current, self.dependencies, self.release)
        return {k: json.loads(v) for k, v in result.items() if k.endswith('.json')} | {
            k: v for k, v in result.items() if not k.endswith('.json')}

    def mutate(self, repo, path, old, new):
        self.api.files[repo, path] = self.api.files[repo, path].replace(old, new)

    def test_production_versions_override_stale_mise(self):
        result = self.prepare()
        deps = result['dependencies/versions.json']
        self.assertEqual(deps['node']['version'], '24.21.0')
        self.assertEqual(deps['ffmpeg']['version'], '7.1.4-3')
        self.assertEqual(deps['python']['version'], '3.12.15')
        self.assertEqual(deps['pgvector']['version'], '0.8.5')
        self.assertEqual(deps['pgvector']['commit'], '6' * 40)
        self.assertEqual(deps['vectorchord']['version'], '1.1.1')
        self.assertEqual(deps['vectorchord']['commit'], '7' * 40)
        self.assertEqual(deps['vectorchord']['pgrx'], '0.17.0')
        self.assertEqual(deps['uv']['version'], '0.12.23')
        self.assertEqual(deps['valkey']['version'], '9.1.2')
        self.assertEqual(deps['winsw']['version'], '2.12.0')
        self.assertEqual(deps['sharpLibvips']['libheif']['version'], '1.23.3')
        self.assertEqual(deps['sharpLibvips']['libheif']['recipeVersion'], '1.23.1')
        self.assertEqual(result['upstream.json']['windowsRevision'], 0)
        self.assertEqual(result['upstream.json']['commit'], 'a' * 40)
        self.assertEqual(deps['upstreamRuntime']['developmentTools']['node'], '24.15.0')

    def test_immutable_source_provenance_and_no_mutation(self):
        before = copy.deepcopy((self.current, self.dependencies))
        first, second = self.prepare(), self.prepare()
        self.assertEqual(first, second)
        self.assertEqual(before, (self.current, self.dependencies))
        deps = first['dependencies/versions.json']
        for name in pins.WINDOWS_PRESERVED:
            self.assertEqual(deps[name], self.dependencies[name])
        for key in ('target', 'variant', 'hevc', 'jpeg', 'repository', 'immichLoaderPatch'):
            self.assertEqual(deps['sharpLibvips'][key], self.dependencies['sharpLibvips'][key])
        self.assertEqual(deps['upstreamRuntime']['baseImages']['commit'], 'b' * 40)
        self.assertEqual(len(deps['upstreamRuntime']['sourceSha256']), 5)
        self.assertEqual(deps['sharpLibvips']['libheif']['recipeSha256'], pins.digest(self.api.files[pins.MXE, 'build/libheif.mk']))

    def test_annotated_tag(self):
        self.api.annotated[pins.IMMICH, 'v3.2.4'] = {'type': 'tag', 'sha': '9' * 40}
        self.api.annotated['9' * 40] = {'sha': '9' * 40, 'object': {'type': 'commit', 'sha': 'a' * 40}}
        self.assertEqual(self.prepare()['upstream.json']['commit'], 'a' * 40)

    def test_cyclic_tag_rejected(self):
        self.api.annotated[pins.IMMICH, 'v3.2.4'] = {'type': 'tag', 'sha': '9' * 40}
        self.api.annotated['9' * 40] = {'sha': '9' * 40, 'object': {'type': 'tag', 'sha': '9' * 40}}
        with self.assertRaisesRegex(ValueError, 'tag chain'):
            self.prepare()

    def test_changed_tag_rejected(self):
        self.release['commit'] = '8' * 40
        with self.assertRaisesRegex(ValueError, 'tag moved'):
            self.prepare()

    def test_prerelease_rejected(self):
        self.release['prerelease'] = True
        with self.assertRaisesRegex(ValueError, 'Only stable'):
            self.prepare()

    def test_missing_asset_digest_rejected(self):
        self.api.asset_digest = None
        with self.assertRaises((TypeError, ValueError)):
            self.prepare()

    def test_missing_windows_asset_rejected(self):
        self.api.assets['jellyfin/jellyfin-ffmpeg'] = ('v7.1.4-3', 'linux-only.tar.gz')
        with self.assertRaisesRegex(ValueError, 'Missing or ambiguous'):
            self.prepare()

    def test_incompatible_python_pin_is_updated_from_standalone_release(self):
        self.mutate(pins.IMMICH, 'machine-learning/pyproject.toml', '>=3.11', '>=3.12')
        result = self.prepare()
        self.assertEqual(result['dependencies/versions.json']['python']['version'], '3.12.15')

    def test_missing_compatible_python_runtime_is_rejected(self):
        self.mutate(pins.IMMICH, 'machine-learning/pyproject.toml', '>=3.11', '>=3.13')
        with self.assertRaisesRegex(ValueError, 'No Windows CPython runtime'):
            self.prepare()

    def test_unmapped_python_syntax_rejected(self):
        self.mutate(pins.IMMICH, 'machine-learning/pyproject.toml', '>=3.11,<4.0', '~=3.11')
        with self.assertRaisesRegex(ValueError, 'Unsupported upstream Python'):
            self.prepare()

    def test_provider_change_rejected(self):
        self.mutate(pins.IMMICH, 'machine-learning/pyproject.toml', 'onnxruntime-openvino', 'onnxruntime-gpu')
        with self.assertRaisesRegex(ValueError, 'DirectML replacement'):
            self.prepare()

    def test_provider_lock_change_rejected(self):
        self.mutate(pins.IMMICH, 'machine-learning/uv.lock', 'onnxruntime-openvino', 'onnxruntime-gpu')
        with self.assertRaisesRegex(ValueError, 'ML lock lacks'):
            self.prepare()

    def test_mismatched_image_tags_rejected(self):
        self.mutate(pins.IMMICH, 'server/Dockerfile', 'base-server-dev:202609281550', 'base-server-dev:202609271550')
        with self.assertRaisesRegex(ValueError, 'production base image'):
            self.prepare()

    def test_ambiguous_production_node_rejected(self):
        self.api.files[pins.BASE, 'server/Dockerfile'] *= 2
        with self.assertRaisesRegex(ValueError, 'production Node'):
            self.prepare()

    def test_new_loader_patch_rejected(self):
        self.api.extra_patch = True
        with self.assertRaisesRegex(ValueError, 'patch set changed'):
            self.prepare()

    def test_changed_loader_patch_is_updated(self):
        self.api.files[pins.BASE, f'server/sources/libvips-patches/{pins.LOADER}'] = 'different patch'
        result = self.prepare()
        self.assertEqual(result['media-patches/libvips/' + pins.LOADER], 'different patch')

    def test_terminal_patch_blank_line_allowed(self):
        self.api.files[pins.BASE, f'server/sources/libvips-patches/{pins.LOADER}'] += '\n'
        self.prepare()

    def test_unmapped_libraw_rejected(self):
        self.mutate(pins.BASE, 'server/sources/libraw.json', '0.22.2-1', '0.22.3')
        with self.assertRaisesRegex(ValueError, 'Unmapped production LibRaw'):
            self.prepare()

    def test_jxl_revision_change_rejected(self):
        self.api.refs['libjxl/libjxl', 'v0.12.0'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'JPEG XL revision'):
            self.prepare()

    def test_unmapped_jxl_rejected(self):
        self.mutate(pins.MXE, 'build/libjxl.mk', '0.12.0', '0.11.0')
        with self.assertRaisesRegex(ValueError, 'JPEG XL differs'):
            self.prepare()

    def test_unmapped_jpegli_rejected(self):
        self.mutate(pins.MXE, 'build/plugins/jpegli/jpegli.mk', 'f' * 40, '0' * 40)
        with self.assertRaisesRegex(ValueError, 'jpegli revision differs'):
            self.prepare()

    def test_libvips_recipe_mismatch_rejected(self):
        self.mutate(pins.MXE, 'build/vips.mk', '8.18.5', '8.18.4')
        with self.assertRaisesRegex(ValueError, 'libvips recipe differs'):
            self.prepare()

    def test_libheif_revision_mismatch_rejected(self):
        self.api.refs['strukturag/libheif', 'v1.23.3'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'libheif revision'):
            self.prepare()

    def test_nonexact_sharp_rejected(self):
        self.mutate(pins.IMMICH, 'server/package.json', '^0.35.3', '>=0.35.3 <1')
        with self.assertRaisesRegex(ValueError, 'Non-exact Sharp'):
            self.prepare()

    def test_windows_patch_is_taken_from_upstream_base(self):
        result = self.prepare()
        self.assertEqual(result['media-patches/libvips/' + pins.LOADER], 'fixture loader patch\n')

    def test_unsupported_platform_rejected(self):
        self.dependencies['target'] = 'win-arm64'
        with self.assertRaisesRegex(ValueError, 'Unsupported Windows'):
            self.prepare()


if __name__ == '__main__':
    unittest.main()
