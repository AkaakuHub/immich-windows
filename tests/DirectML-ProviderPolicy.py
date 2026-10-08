"""Regressions for provider policy and optional ONNX embedding transformations.

Test runtime behavior, never source text or implementation structure.
Mocks model ORT's registered providers, not GPU execution. Real DirectML
inference still requires the packaged Windows smoke test on suitable hardware.
"""

import io
import os
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parent.parent
MODEL_SOURCE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None
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
                self.assertEqual(options["provider_options"], [{"device_id": "2", "disable_metacommands": "true"}])
                self.assertIs(options["enable_fallback"], False)
                self.assertEqual(options["sess_options"].entries, {
                    "session.disable_cpu_ep_fallback": "1", "ep.dml.disable_graph_fusion": "1",
                })
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


@unittest.skipUnless(MODEL_SOURCE, "Requires the packaged ML source and ONNX dependencies")
class GraphInferenceTests(unittest.TestCase):
    def setUp(self):
        import numpy as np
        import onnx
        import onnxruntime as ort

        sys.path.insert(0, str(MODEL_SOURCE))
        self.addCleanup(sys.path.remove, str(MODEL_SOURCE))
        from immich_ml.sessions import ort as graph_module

        self.np, self.onnx, self.ort = np, onnx, ort
        self.graph_module = graph_module
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name) / "model.onnx"
        graph = onnx.helper.make_graph(
            [onnx.helper.make_node("Add", ["x", "x"], ["y"])], "graph-test",
            [onnx.helper.make_tensor_value_info("x", onnx.TensorProto.FLOAT, [1, 2])],
            [onnx.helper.make_tensor_value_info("y", onnx.TensorProto.FLOAT, [1, 2])],
        )
        model = onnx.helper.make_model(graph, opset_imports=[onnx.helper.make_opsetid("", 13)], ir_version=8)
        onnx.save_model(model, self.source)

    def test_windows_default_uses_only_the_selected_accelerator(self):
        for accelerator, expected in (("directml", DML), ("cpu", CPU)):
            with self.subTest(accelerator=accelerator), patch.object(self.graph_module.sys, "platform", "win32"), patch.dict(
                "os.environ", {"MACHINE_LEARNING_ACCELERATOR": accelerator}
            ), patch.object(self.graph_module.ort, "get_available_providers", return_value=[DML, CPU]):
                self.assertEqual(self.graph_module._providers_default(), [expected])

    def test_windows_unavailable_directml_does_not_select_cpu(self):
        with patch.object(self.graph_module.sys, "platform", "win32"), patch.dict(
            "os.environ", {"MACHINE_LEARNING_ACCELERATOR": "directml"}
        ), patch.object(self.graph_module.ort, "get_available_providers", return_value=[CPU]):
            with self.assertRaises(RuntimeError):
                self.graph_module._providers_default()

    def test_directml_session_options_disable_parallel_execution_and_cpu_fallback(self):
        spec = self.graph_module.GraphSpec(self.source, {}, (), [DML], [])
        with patch.object(self.graph_module.settings, "model_inter_op_threads", 2):
            options = spec.sess_options()
        self.assertFalse(options.enable_mem_pattern)
        self.assertEqual(options.execution_mode, self.ort.ExecutionMode.ORT_SEQUENTIAL)
        self.assertEqual(options.get_session_config_entry("session.disable_cpu_ep_fallback"), "1")
        self.assertEqual(options.get_session_config_entry("ep.dml.disable_graph_fusion"), "1")

    def test_packaged_graph_runs_concurrent_requests_with_correct_outputs(self):
        spec = SimpleNamespace(provider=DML, session=lambda path: self.ort.InferenceSession(str(path), providers=[CPU]))
        with patch.object(self.graph_module, "prepared", return_value=self.source):
            graph = self.graph_module.OrtGraph(spec)
        inputs = [self.np.array([[float(i), float(i + 1)]], dtype=self.np.float32) for i in range(8)]
        with ThreadPoolExecutor(2) as pool:
            outputs = list(pool.map(lambda value: graph.run(None, {"x": value})[0], inputs))
        for value, output in zip(inputs, outputs):
            self.np.testing.assert_array_equal(output, value * 2)

    def test_concurrent_child_preparation_produces_a_runnable_graph(self):
        spec = self.graph_module.GraphSpec(self.source, {}, (), [DML], [])
        with patch.dict(os.environ, {"PYTHONPATH": str(MODEL_SOURCE), "MACHINE_LEARNING_MODEL_REVISION": "main"}), patch.object(
            self.graph_module.settings, "model_revision", "main"
        ), ThreadPoolExecutor(2) as pool:
            graphs = list(pool.map(self.graph_module.prepared, [spec, spec]))
        self.assertEqual(graphs[0], graphs[1])
        session = self.ort.InferenceSession(str(graphs[0]), providers=[CPU])
        value = self.np.array([[1.0, 2.0]], dtype=self.np.float32)
        self.np.testing.assert_array_equal(session.run(None, {"x": value})[0], value * 2)

    def test_session_initialization_failure_is_not_retried(self):
        failure = RuntimeError("session initialization failed")
        factory = Mock(side_effect=failure)
        spec = SimpleNamespace(provider=DML, session=factory)
        with patch.object(self.graph_module, "prepared", return_value=self.source):
            with self.assertRaises(RuntimeError) as caught:
                self.graph_module.OrtGraph(spec)
        self.assertIs(caught.exception, failure)
        factory.assert_called_once()


if __name__ == "__main__":
    unittest.main()
