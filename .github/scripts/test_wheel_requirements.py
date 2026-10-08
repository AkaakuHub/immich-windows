"""Exercise generated wheel metadata and requirement conversion, never source text."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location(
    "wheel_requirements", Path(__file__).resolve().parents[2] / "build/Normalize-WheelRequirements.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WheelRequirementsTests(unittest.TestCase):
    def test_source_requirement_uses_built_wheel_identity_and_preserves_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requirements, output = root / "requirements.txt", root / "wheel-requirements.txt"
            requirements.write_text(
                "immich-model @ https://example.invalid/pinned.tar.gz ; python_version >= '3.12'\n"
                "opencv-python==1.0 ; sys_platform == 'never'\n"
                "opencv-python-headless==2.0\n", encoding="utf-8"
            )
            with zipfile.ZipFile(root / "immich_model-0.2.0-py3-none-any.whl", "w") as wheel:
                wheel.writestr("immich_model-0.2.0.dist-info/METADATA", "Name: immich_model\nVersion: 0.2.0\n")
            original = requirements.read_bytes()
            module.normalize(requirements, root, output)
            self.assertEqual(output.read_text(),
                             "immich-model==0.2.0 ; python_version >= '3.12'\n"
                             "opencv-python==1.0 ; sys_platform == 'never'\n"
                             "opencv-python-headless==2.0\n")
            self.assertEqual(requirements.read_bytes(), original)

    def test_missing_built_source_wheel_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requirements = root / "requirements.txt"
            requirements.write_text("missing @ https://example.invalid/pinned.tar.gz\n", encoding="utf-8")
            with self.assertRaises(KeyError):
                module.normalize(requirements, root, root / "output.txt")
