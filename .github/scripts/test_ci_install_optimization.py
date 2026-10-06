"""Offline checks for retained coverage when consolidating installed CI probes."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def sharp_probe(path):
    return path.read_text(encoding='utf-8').split("$probe=@'\n", 1)[1].split("\n'@", 1)[0]


class InstalledProbeTests(unittest.TestCase):
    def test_media_only_probe_keeps_the_exact_packaged_smoke_javascript_and_native_gate(self):
        helper = ROOT / 'tests/actions/Test-InstalledMediaFixtures.ps1'
        self.assertEqual(sharp_probe(helper), sharp_probe(ROOT / 'tests/Smoke-Windows.ps1'))
        source = helper.read_text(encoding='utf-8')
        self.assertIn("Join-Path $ReleaseRoot 'runtime/Native-Probe.psm1'", source)
        self.assertIn('Invoke-ImmichNativeProbe -FilePath $node', source)
        self.assertIn("Join-Path $ReleaseRoot 'runtime/node/node.exe'", source)
        self.assertIn('finally { $env:PATH = $previousPath }', source)

    @unittest.skipUnless(shutil.which('node'), 'Node is needed for the real embedded fixture probe')
    def test_actual_probe_uses_all_fixture_paths_and_propagates_a_decode_failure(self):
        probe = sharp_probe(ROOT / 'tests/actions/Test-InstalledMediaFixtures.ps1')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / 'server/node_modules/sharp'
            package.mkdir(parents=True)
            (root / 'server/package.json').write_text('{}', encoding='utf-8')
            (package / 'index.js').write_text('''
function sharp(file) { return {
  async metadata() { if (file.includes('broken')) throw new Error('decode failure');
    return {format:'fixture',width:1,height:1}; },
  resize() { return this; }, jpeg() { return this; }, async toBuffer() { return Buffer.alloc(0); }
}; }
sharp.versions = {sharp:'fixture',vips:'fixture'}; module.exports = sharp;
''', encoding='utf-8')
            fixtures = [str(root / name) for name in ('one image.heic', '日本語.jxl', 'three.dng')]
            result = subprocess.run(['node', '-e', probe, str(root / 'server'), *fixtures],
                                    capture_output=True, text=True, encoding='utf-8')
            self.assertEqual(result.returncode, 0, result.stderr)
            for path in fixtures:
                self.assertIn(f'sharp fixture OK: {path}', result.stdout)
            failure = subprocess.run(['node', '-e', probe, str(root / 'server'), 'broken.heic'],
                                     capture_output=True, text=True, encoding='utf-8')
            self.assertNotEqual(failure.returncode, 0)
            self.assertIn('decode failure', failure.stderr)

    def test_workflow_runs_each_upgrade_lifecycle_and_unique_fixture_probe_once(self):
        workflow = (ROOT / '.github/workflows/build-windows.yml').read_text(encoding='utf-8')
        lines = [line for line in workflow.splitlines() if './tests/actions/Test-RevisionUpgrade.ps1' in line]
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertIn('-SharpFixture $fixtures -TestMachineLearningLifecycle', line)
        self.assertNotIn('./tests/actions/Test-MachineLearningLifecycle.ps1', workflow)
        self.assertEqual(workflow.count('& "$packageRoot/tests/Smoke-Windows.ps1"'), 1)
        self.assertIn('Fresh AllUsers candidate qualification passed', workflow)
        lifecycle = (ROOT / 'tests/actions/Test-MachineLearningLifecycle.ps1').read_text(encoding='utf-8')
        self.assertIn('foreach ($cycle in 1..3)', lifecycle)
        self.assertIn('AddSeconds(4)', lifecycle)
        self.assertIn('Running lifecycle fixture is not configured:', lifecycle)
        upgrade = (ROOT / 'tests/actions/Test-RevisionUpgrade.ps1').read_text(encoding='utf-8')
        self.assertIn('-UseRunningConfiguration -LeaveStopped', upgrade)
        self.assertIn('Test-InstalledMediaFixtures.ps1', upgrade)
        self.assertIn('[IO.File]::WriteAllBytes($envFile, $lifecycleOriginalEnv)', upgrade)


if __name__ == '__main__':
    unittest.main()
