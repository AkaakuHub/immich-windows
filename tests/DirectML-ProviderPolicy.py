"""Regressions for provider policy and optional ONNX embedding transformations.

Mocks model ORT's registered providers, not GPU execution. Real DirectML
inference still requires the packaged Windows smoke test on suitable hardware.
"""

import io
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from pathlib import Path
from threading import Barrier
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


@unittest.skipUnless(MODEL_SOURCE, "Requires the prepared or packaged ML source and its ONNX dependencies")
class EmbeddingModelTests(unittest.TestCase):
    def setUp(self):
        import numpy as np
        import onnx
        import onnxruntime as ort

        sys.path.insert(0, str(MODEL_SOURCE))
        from immich_ml.sessions import directml, onnx_external

        self.addCleanup(sys.path.remove, str(MODEL_SOURCE))
        self.np, self.onnx, self.ort = np, onnx, ort
        self.directml, self.reader = directml, onnx_external
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "model.onnx"
        self.weights = np.arange(19 * 4, dtype=np.float32).reshape(19, 4) - 30
        tensor = onnx.numpy_helper.from_array(self.weights, name="embedding")
        graph = onnx.helper.make_graph(
            [onnx.helper.make_node("Gather", ["embedding", "tokens"], ["vectors"], axis=0)], "embedding-test",
            [onnx.helper.make_tensor_value_info("tokens", onnx.TensorProto.INT32, [1, None])],
            [onnx.helper.make_tensor_value_info("vectors", onnx.TensorProto.FLOAT, [1, None, 4])], [tensor],
        )
        self.model = onnx.helper.make_model(graph, opset_imports=[onnx.helper.make_opsetid("", 17)], ir_version=8)
        self.onnx.save_model(self.model, self.source)

    def compare(self):
        before = self.source.read_bytes()
        tokens = self.np.array([[0, 5, 6, 11, 12, 17, 18, -1, -19]], dtype=self.np.int32)
        with patch.object(self.directml, "MAX_EMBEDDING_BYTES", 96):
            with self.directml.directml_model(self.source) as prepared:
                self.assertNotEqual(prepared, self.source)
                self.onnx.checker.check_model(str(prepared))
                model = self.onnx.load_model(prepared, load_external_data=False)
                self.assertTrue(all(not tensor.raw_data for tensor in model.graph.initializer))
                reference = self.ort.InferenceSession(str(self.source), providers=[CPU])
                session = self.ort.InferenceSession(str(prepared), providers=[CPU])
                self.np.testing.assert_array_equal(
                    session.run(None, {"tokens": tokens})[0], reference.run(None, {"tokens": tokens})[0],
                )
                self.np.testing.assert_array_equal(session.run(None, {"tokens": tokens})[0], self.weights[tokens])
            self.assertFalse(prepared.exists())
        self.assertEqual(self.source.read_bytes(), before)

    def test_shard_boundaries_last_partial_shard_and_negative_indices_preserve_weights(self):
        self.compare()

    def test_existing_external_weights_are_referenced_without_copying(self):
        self.onnx.save_model(self.model, self.source, save_as_external_data=True,
                             all_tensors_to_one_file=True, location="weights.bin", size_threshold=0)
        before = (self.root / "weights.bin").read_bytes()
        self.compare()
        self.assertEqual((self.root / "weights.bin").read_bytes(), before)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["model.onnx", "weights.bin"])

    def test_small_model_uses_original_file(self):
        with self.directml.directml_model(self.source) as prepared:
            self.assertEqual(prepared, self.source)
        self.assertEqual(list(self.root.iterdir()), [self.source])

    def test_generated_header_is_removed_when_session_creation_fails(self):
        with patch.object(self.directml, "MAX_EMBEDDING_BYTES", 96):
            with self.assertRaisesRegex(RuntimeError, "session failure"):
                with self.directml.directml_model(self.source) as prepared:
                    self.assertTrue(prepared.exists())
                    raise RuntimeError("session failure")
        self.assertEqual(list(self.root.iterdir()), [self.source])

    def test_reader_does_not_read_raw_initializer_payload(self):
        payload = self.source.read_bytes()
        raw = self.model.graph.initializer[0].raw_data

        class ObservedStream(io.BytesIO):
            def read(stream, size=-1):
                result = super().read(size)
                self.assertNotIn(raw, result)
                return result

        with patch.object(Path, "open", return_value=ObservedStream(payload)):
            model = self.reader.read_external_model(self.source)
        self.assertFalse(model.graph.initializer[0].raw_data)
        self.assertEqual(model.graph.initializer[0].data_location, self.onnx.TensorProto.EXTERNAL)


@unittest.skipUnless(MODEL_SOURCE, "Requires the prepared ML source and ONNX dependencies")
class DynamicModelTests(unittest.TestCase):
    def setUp(self):
        EmbeddingModelTests.setUp(self)
        from immich_ml.sessions.directml_dynamic import dynamic_session

        self.prepare = dynamic_session
        self.created_shapes = []
        self.original = self.source.read_bytes()

    def create_session(self, shapes):
        self.created_shapes.append(shapes)
        with self.directml.directml_model(self.source, shapes) as prepared:
            self.onnx.checker.check_model(str(prepared))
            return self.ort.InferenceSession(str(prepared), providers=[CPU], enable_fallback=False)

    def test_shape_changes_preserve_results_and_reuse_only_matching_session(self):
        session = self.prepare(self.source, self.create_session)
        self.assertEqual(session.get_inputs()[0].shape, (1, None))
        for values in ([[0, 18]], [[1, 3]], [[0, 5, 18]], [[18, 0]]):
            tokens = self.np.array(values, dtype=self.np.int32)
            output = session.run(None, {"tokens": tokens})[0]
            self.np.testing.assert_array_equal(output, self.weights[tokens])
        self.assertEqual(self.created_shapes, [
            {"tokens": (1, 2)}, {"tokens": (1, 3)}, {"tokens": (1, 2)},
        ])
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(list(self.root.iterdir()), [self.source])

    def test_fixed_dimension_and_input_name_mismatches_fail(self):
        session = self.prepare(self.source, self.create_session)
        with self.assertRaisesRegex(ValueError, "input names"):
            session.run(None, {"wrong": self.np.zeros((1, 2), dtype=self.np.int32)})
        self.assertEqual(self.created_shapes, [])
        with self.assertRaisesRegex(ValueError, "Invalid input shape"):
            session.run(None, {"tokens": self.np.zeros((2, 2), dtype=self.np.int32)})

    def test_initialization_failure_does_not_retry_or_keep_previous_shape(self):
        failure = RuntimeError("DirectML initialization failed")
        factory = Mock(side_effect=failure)
        session = self.prepare(self.source, factory)
        with self.assertRaises(RuntimeError) as caught:
            session.run(None, {"tokens": self.np.zeros((1, 2), dtype=self.np.int32)})
        self.assertIs(caught.exception, failure)
        factory.assert_called_once_with({"tokens": (1, 2)})
        self.assertIsNone(session.session)
        self.assertIsNone(session.input_shapes)

    def test_static_models_keep_eager_session_creation(self):
        self.model.graph.input[0].type.tensor_type.shape.dim[1].dim_value = 3
        self.onnx.save_model(self.model, self.source)
        factory = Mock()
        session = self.prepare(self.source, factory)
        self.assertIs(session.session, factory.return_value)
        factory.assert_called_once_with(None)

    def test_parallel_threads_keep_distinct_sessions_and_shapes(self):
        barrier = Barrier(2)
        session = self.prepare(self.source, self.create_session)

        def infer(length):
            tokens = self.np.arange(length, dtype=self.np.int32).reshape(1, length)
            output = session.run(None, {"tokens": tokens})[0]
            native_session = session.session
            barrier.wait(timeout=10)
            self.assertIs(session.session, native_session)
            self.assertEqual(session.input_shapes, {"tokens": (1, length)})
            self.np.testing.assert_array_equal(output, self.weights[tokens])
            return native_session

        with ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(infer, 2)
            second = executor.submit(infer, 3)
            self.assertIsNot(first.result(), second.result())
        self.assertIsNone(session.session)

    def test_small_and_empty_resize_constants_are_available_to_shape_inference(self):
        helper, tensor = self.onnx.helper, self.onnx.TensorProto
        graph = helper.make_graph(
            [helper.make_node("Resize", ["image", "roi", "", "sizes"], ["output"], mode="nearest")],
            "resize-test", [helper.make_tensor_value_info("image", tensor.FLOAT, [None, None])],
            [helper.make_tensor_value_info("output", tensor.FLOAT, [2, 2])],
            [helper.make_tensor("roi", tensor.FLOAT, [0], []),
             self.onnx.numpy_helper.from_array(self.np.array([2, 2], dtype=self.np.int64), "sizes")],
        )
        model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)], ir_version=8)
        model.metadata_props.add(key="character", value="a\nb")
        self.onnx.save_model(model, self.source)
        session = self.prepare(self.source, self.create_session)
        self.assertEqual(session.metadata, {"character": "a\nb"})
        image = self.np.arange(16, dtype=self.np.float32).reshape(4, 4)
        reference = self.ort.InferenceSession(str(self.source), providers=[CPU])
        self.np.testing.assert_array_equal(
            session.run(None, {"image": image})[0], reference.run(None, {"image": image})[0],
        )


if __name__ == "__main__":
    unittest.main()
