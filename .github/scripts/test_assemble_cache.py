"""Offline wiring checks for the narrow Corepack download-cache addition."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / '.github/workflows/build-windows.yml').read_text(encoding='utf-8')
ASSEMBLE = WORKFLOW.split('\n  assemble:\n', 1)[1].split('\n  publish:\n', 1)[0]
STEPS = re.split(r'(?=^      - )', ASSEMBLE, flags=re.MULTILINE)[1:]
INPUTS = "${{ hashFiles('dependencies/versions.json', 'build/Bootstrap-BuildTools.ps1', 'build/Fetch-NodeRuntime.ps1', 'tests/Fetch-MediaFixtures.ps1') }}"


def step_containing(text):
    matches = [step for step in STEPS if text in step]
    if len(matches) != 1:
        raise AssertionError(f'Expected one step containing {text!r}, found {len(matches)}')
    return matches[0]


class AssembleCacheTests(unittest.TestCase):
    def test_corepack_is_inside_the_existing_cache_and_only_affects_build_preparation(self):
        build = step_containing('- name: Build and qualify Windows package')
        self.assertIn('        env:\n', build)
        self.assertIn('COREPACK_HOME: ${{ github.workspace }}/.cache/corepack', build)
        self.assertEqual(WORKFLOW.count('COREPACK_HOME:'), 1)
        restore = step_containing('id: build-downloads\n')
        self.assertIn('          path: .cache\n', restore)

    def test_new_key_includes_the_same_pins_and_scripts_as_the_archive_cache(self):
        restore = step_containing('id: build-downloads\n')
        self.assertIn('key: build-downloads-corepack-v1-${{ runner.os }}-' + INPUTS, restore)
        # Only the old cache with these exact inputs may seed the first new key.
        fallback = re.search(r'^          restore-keys: (.+)$', restore, re.MULTILINE)
        self.assertIsNotNone(fallback)
        self.assertEqual(fallback.group(1), 'build-downloads-${{ runner.os }}-' + INPUTS)
        pins = (ROOT / 'dependencies/versions.json').read_text(encoding='utf-8')
        for tool in ('node', 'pnpm', 'uv', 'extismJs', 'binaryen'):
            self.assertIn(f'"{tool}":', pins)

    def test_old_cache_seed_is_saved_under_the_new_primary_key_only_after_success(self):
        save = step_containing("if: steps.build-downloads.outputs.cache-hit != 'true'")
        self.assertIn('uses: actions/cache/save@', save)
        self.assertIn('          path: .cache\n', save)
        self.assertIn('key: ${{ steps.build-downloads.outputs.cache-primary-key }}', save)
        self.assertNotIn('always()', save)
        self.assertGreater(STEPS.index(save), STEPS.index(step_containing('- name: Build and qualify Windows package')))

    def test_cache_hit_does_not_skip_bootstrap_or_pinned_tool_validation(self):
        build = step_containing('- name: Build and qualify Windows package')
        self.assertNotIn('        if:', build)
        self.assertIn('.\\build\\Build-All.ps1 -SkipNativeDependencies', build)
        all_source = (ROOT / 'build/Build-All.ps1').read_text(encoding='utf-8')
        self.assertIn("& (Join-Path $PSScriptRoot 'Bootstrap-BuildTools.ps1') | Out-Host", all_source)
        bootstrap = (ROOT / 'build/Bootstrap-BuildTools.ps1').read_text(encoding='utf-8')
        self.assertIn("@('prepare',\"pnpm@$($versions.pnpm.version)\",'--activate')", bootstrap)
        self.assertIn('if ($pnpmVersion -ne $versions.pnpm.version) { throw', bootstrap)
        self.assertIn('if ($nodeVersion -ne $versions.node.version) { throw', bootstrap)
        self.assertIn('throw "Unexpected uv version: $uvVersion"', bootstrap)
        self.assertNotIn('COREPACK_INTEGRITY_KEYS', WORKFLOW)

    def test_no_bulk_tools_or_profile_cache_is_added(self):
        restores = [step for step in STEPS if 'uses: actions/cache/restore@' in step]
        saves = [step for step in STEPS if 'uses: actions/cache/save@' in step]
        self.assertEqual(len(restores), 5)
        self.assertEqual(len(saves), 5)
        for step in restores + saves:
            self.assertNotIn('.tools', step)
            self.assertNotIn('LOCALAPPDATA', step)
            self.assertNotIn('USERPROFILE', step)


if __name__ == '__main__':
    unittest.main()
