"""Dependency-free regressions for the embedded selected-provider smoke probe.

Mocks model ORT's registered providers, not GPU execution. Real DirectML
inference still requires the packaged Windows smoke test on suitable hardware.
"""

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parent.parent
PROBE = (ROOT / "tests/Smoke-Windows.ps1").read_text(encoding="utf-8").split("$ortProbe=@'\n", 1)[1].split("\n'@", 1)[0]
DML, CPU = "DmlExecutionProvider", "CPUExecutionProvider"


class Options:
    def __init__(self):
        self.entries = {}
        self.enable_mem_pattern = True
        self.execution_mode = "parallel"

    def add_session_config_entry(self, key, value):
        self.entries[key] = value


class SmokePolicyTests(unittest.TestCase):
    def setUp(self):
        self.session = Mock()
        self.session.run.return_value = [[[2.0, 4.0]]]
        self.factory = Mock(return_value=self.session)
        self.ort = SimpleNamespace(
            __version__="1.24.4", get_available_providers=lambda: [DML, CPU],
            SessionOptions=Options, ExecutionMode=SimpleNamespace(ORT_SEQUENTIAL="sequential"),
            InferenceSession=self.factory,
        )
        helper = Mock()
        helper.make_model.return_value.SerializeToString.return_value = b"tiny-add-graph"
        self.modules = {
            "onnxruntime": self.ort,
            "onnx": SimpleNamespace(TensorProto=SimpleNamespace(FLOAT=1), helper=helper),
            "numpy": SimpleNamespace(float32="float32", array=lambda value, **kwargs: value,
                                     testing=SimpleNamespace(assert_array_equal=self.assertEqual)),
        }

    def run_probe(self, registered, accelerator="directml"):
        self.session.get_providers.return_value = registered
        with patch.dict(sys.modules, self.modules), patch.object(sys, "argv", ["probe", "1.24.4", accelerator, "2"]):
            with redirect_stdout(io.StringIO()):
                exec(compile(PROBE, "Smoke-Windows.ps1:ortProbe", "exec"), {})

    def test_directml_allows_implicit_cpu_registration_and_keeps_strict_options(self):
        for registered in ([DML], [DML, CPU]):
            with self.subTest(registered=registered):
                self.factory.reset_mock()
                self.session.run.reset_mock()
                self.run_probe(registered)
                self.factory.assert_called_once()
                self.session.run.assert_called_once()
                options = self.factory.call_args.kwargs
                self.assertEqual(options["providers"], [DML])
                self.assertEqual(options["provider_options"], [{"device_id": "2"}])
                self.assertIs(options["enable_fallback"], False)
                self.assertEqual(options["sess_options"].entries, {"session.disable_cpu_ep_fallback": "1"})
                self.assertIs(options["sess_options"].enable_mem_pattern, False)
                self.assertEqual(options["sess_options"].execution_mode, "sequential")

    def test_directml_rejects_missing_reordered_or_unexpected_providers(self):
        for registered in ([], [CPU], [CPU, DML], [DML, "UnexpectedExecutionProvider"], [DML, CPU, "UnexpectedExecutionProvider"]):
            with self.subTest(registered=registered), self.assertRaises(RuntimeError):
                self.run_probe(registered)
        self.session.run.assert_not_called()

    def test_cpu_remains_explicit_without_directml_constraints(self):
        self.run_probe([CPU], accelerator="cpu")
        options = self.factory.call_args.kwargs
        self.assertEqual(options["providers"], [CPU])
        self.assertEqual(options["sess_options"].entries, {})
        self.assertIs(options["enable_fallback"], False)

    def test_cpu_rejects_other_registered_providers(self):
        for registered in ([], [DML], [DML, CPU], [CPU, DML], [CPU, CPU]):
            with self.subTest(registered=registered), self.assertRaises(RuntimeError):
                self.run_probe(registered, accelerator="cpu")
        self.session.run.assert_not_called()

    def test_constructor_failure_propagates_without_retry(self):
        failure = RuntimeError("CPU-assigned graph nodes rejected by strict ORT configuration")
        self.factory.side_effect = failure
        with self.assertRaises(RuntimeError) as caught:
            self.run_probe([DML, CPU])
        self.assertIs(caught.exception, failure)
        self.factory.assert_called_once()
        self.session.run.assert_not_called()

    def test_inference_failure_propagates_without_retry(self):
        failure = RuntimeError("DirectML execution failed")
        self.session.run.side_effect = failure
        with self.assertRaises(RuntimeError) as caught:
            self.run_probe([DML, CPU])
        self.assertIs(caught.exception, failure)
        self.factory.assert_called_once()
        self.session.run.assert_called_once()

    def test_incorrect_output_fails(self):
        self.session.run.return_value = [[[0.0, 0.0]]]
        with self.assertRaises(AssertionError):
            self.run_probe([DML, CPU])

    def test_unavailable_directml_fails_before_session_creation(self):
        self.ort.get_available_providers = lambda: [CPU]
        with self.assertRaises(RuntimeError):
            self.run_probe([CPU])
        self.factory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
