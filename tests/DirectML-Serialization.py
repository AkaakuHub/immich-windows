import ast
import sys
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
from pathlib import Path
from threading import Event, Lock
from types import SimpleNamespace
from unittest.mock import Mock, patch


SOURCE = Path(sys.argv.pop(1)) / "machine-learning" / "immich_ml" / "sessions" / "ort.py"
DML, CPU = "DmlExecutionProvider", "CPUExecutionProvider"


class Options:
    execution_mode = SimpleNamespace(name="ORT_SEQUENTIAL")
    inter_op_num_threads = 1
    intra_op_num_threads = 1

    def add_session_config_entry(self, key, value):
        pass


class DirectMLConcurrencyTests(unittest.TestCase):
    def setUp(self):
        tree = ast.parse(SOURCE.read_text(encoding="utf-8"))
        nodes = [ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)]
        nodes.extend(node for node in tree.body if isinstance(node, (ast.Assign, ast.AnnAssign, ast.ClassDef)))
        self.factory = Mock(side_effect=lambda *args, **kwargs: self.native_session())
        self.settings = SimpleNamespace(accelerator="directml")
        namespace = dict(
            Lock=Lock, Path=Path, sys=SimpleNamespace(platform="win32"), nullcontext=nullcontext, log=Mock(),
            settings=self.settings,
            ort=SimpleNamespace(InferenceSession=self.factory,
                                ExecutionMode=SimpleNamespace(ORT_SEQUENTIAL="sequential")),
            directml_model=lambda source, shapes: nullcontext(source), dynamic_session=lambda *args: None,
        )
        code = ast.fix_missing_locations(ast.Module(body=nodes, type_ignores=[]))
        exec(compile(code, str(SOURCE), "exec"), namespace)
        self.session_type = namespace["OrtSession"]

    def native_session(self):
        session = Mock()
        session.get_providers.return_value = [DML, CPU]
        return session

    def session(self, provider=DML):
        with patch.object(self.settings, "accelerator", "cpu" if provider == CPU else "directml"):
            return self.session_type("model.onnx", providers=[provider],
                                     provider_options=[{"device_id": "1"}], sess_options=Options())

    def check_concurrency(self, first, second, parallel):
        entered_first, entered_second, started_second, release_first = Event(), Event(), Event(), Event()

        def block_first(*args, **kwargs):
            entered_first.set()
            if not release_first.wait(3):
                raise AssertionError("First operation was not released")
            return []

        first.session.run.side_effect = block_first

        def enter_second(*args, **kwargs):
            entered_second.set()
            return self.native_session()

        if second is None:
            self.factory.side_effect = enter_second
            action = self.session
        else:
            second.session.run.side_effect = enter_second
            action = lambda: second.run(None, {})

        def start_second():
            started_second.set()
            return action()

        with ThreadPoolExecutor(2) as pool:
            first_result = pool.submit(first.run, None, {})
            try:
                self.assertTrue(entered_first.wait(2))
                second_result = pool.submit(start_second)
                self.assertTrue(started_second.wait(2))
                self.assertEqual(entered_second.wait(0.15), parallel)
            finally:
                release_first.set()
            first_result.result(timeout=2)
            second_result.result(timeout=2)
        self.assertTrue(entered_second.is_set())

    def test_different_directml_models_do_not_run_simultaneously(self):
        self.check_concurrency(self.session(), self.session(), parallel=False)

    def test_directml_model_creation_waits_for_another_model_run(self):
        self.check_concurrency(self.session(), None, parallel=False)

    def test_cpu_model_can_run_while_directml_is_running(self):
        self.check_concurrency(self.session(), self.session(CPU), parallel=True)

    def test_directml_exception_releases_other_models(self):
        first, second = self.session(), self.session()
        failure = RuntimeError("GPU execution failed")
        first.session.run.side_effect = failure
        with self.assertRaises(RuntimeError) as caught:
            first.run(None, {})
        self.assertIs(caught.exception, failure)
        second.run(None, {})
        second.session.run.assert_called_once_with(None, {}, None)


if __name__ == "__main__":
    unittest.main()
