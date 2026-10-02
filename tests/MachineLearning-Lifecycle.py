"""Dependency-free checks against the prepared, pinned Immich source."""

import ast
import asyncio
import builtins
import pickle
import signal
import sys
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch


SOURCE = Path(sys.argv.pop(1)) / "machine-learning" / "immich_ml"


def read_tree(name):
    return ast.parse((SOURCE / name).read_text(encoding="utf-8"))


def compile_nodes(nodes, filename):
    return compile(ast.fix_missing_locations(ast.Module(body=nodes, type_ignores=[])), filename, "exec")


class SupervisorImportTests(unittest.TestCase):
    def setUp(self):
        self.package = ModuleType("immich_ml")
        self.package.__path__ = [str(SOURCE)]
        self.modules = patch.dict(sys.modules, {"immich_ml": self.package})
        self.modules.start()
        self.addCleanup(self.modules.stop)

        # The shared enums must stay usable before any third-party imports.
        original_import = builtins.__import__

        def stdlib_only(name, *args, **kwargs):
            if name.split(".")[0] not in sys.stdlib_module_names:
                raise AssertionError(f"Shared enums imported a non-stdlib module: {name}")
            return original_import(name, *args, **kwargs)

        with patch("builtins.__import__", stdlib_only):
            exec(compile_nodes(read_tree("__init__.py").body, "__init__.py"), self.package.__dict__)

    def shared_imports(self, filename):
        nodes = [node for node in read_tree(filename).body if isinstance(node, ast.ImportFrom)
                 and any(alias.name in {"ModelPrecision", "StrEnum"} for alias in node.names)]
        self.assertTrue(nodes, f"{filename} must import the shared enums")
        for node in nodes:
            self.assertEqual((node.level, node.module), (1, None))
        namespace = {"__package__": "immich_ml"}
        exec(compile_nodes(nodes, filename), namespace)
        return namespace

    def test_config_precision_does_not_import_schemas(self):
        config = self.shared_imports("config.py")
        self.assertIs(config["ModelPrecision"], self.package.ModelPrecision)
        self.assertNotIn("immich_ml.schemas", sys.modules)

    def test_schema_exports_preserve_identity_and_enum_behavior(self):
        schemas = self.shared_imports("schemas.py")
        self.assertIs(schemas["ModelPrecision"], self.package.ModelPrecision)
        self.assertIs(schemas["StrEnum"], self.package.StrEnum)
        self.assertEqual(list(self.package.ModelPrecision), ["FP16", "FP32"])
        self.assertEqual(str(self.package.ModelPrecision.FP32), "FP32")
        self.assertIs(self.package.ModelPrecision("FP16"), self.package.ModelPrecision.FP16)
        self.assertTrue(issubclass(self.package.ModelPrecision, schemas["StrEnum"]))
        for filename in ("config.py", "schemas.py"):
            self.assertFalse(any(isinstance(node, ast.ClassDef) and node.name in {"ModelPrecision", "StrEnum"}
                                 for node in read_tree(filename).body))

    def test_precision_pickle_compatibility(self):
        schemas = ModuleType("immich_ml.schemas")
        schemas.__dict__.update(self.shared_imports("schemas.py"))
        with patch.dict(sys.modules, {"immich_ml.schemas": schemas}):
            old_pickle = b"cimmich_ml.schemas\nModelPrecision\n(VFP32\ntR."
            self.assertIs(pickle.loads(old_pickle), self.package.ModelPrecision.FP32)
            self.assertIs(pickle.loads(pickle.dumps(self.package.ModelPrecision.FP16)),
                          self.package.ModelPrecision.FP16)


class LauncherTests(unittest.TestCase):
    def launch(self, workers=1, failure=None):
        tree = read_tree("__main__.py")
        branch = next(node for node in tree.body if isinstance(node, ast.If)
                      and ast.unparse(node.test) == "sys.platform == 'win32'")
        config = Mock()
        # A real context manager makes closure observable on success and failure.
        class BoundSocket:
            closed = False

            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.closed = True

        socket = BoundSocket()
        config.bind_socket.return_value = socket
        server_class = Mock()
        uvicorn = SimpleNamespace(Config=Mock(return_value=config), Server=server_class)
        supervisor = Mock()
        supervisor.return_value.run.side_effect = failure
        namespace = dict(non_prefixed_settings=SimpleNamespace(immich_host="[::1]", immich_port=3210),
                         settings=SimpleNamespace(workers=workers, http_keepalive_timeout_s=7),
                         module_dir=SOURCE, __package__="immich_ml")
        with patch.dict(sys.modules, {"uvicorn": uvicorn,
                                     "uvicorn.supervisors": SimpleNamespace(Multiprocess=supervisor)}):
            with self.assertRaises(type(failure) if failure else SystemExit) as caught:
                exec(compile_nodes(branch.body, "__main__.py"), namespace)
        if not failure:
            self.assertEqual(caught.exception.code, 0)
        uvicorn.Config.assert_called_once_with("immich_ml.main:app", host="::1", port=3210,
                                               workers=workers, loop="asyncio:SelectorEventLoop", timeout_keep_alive=7,
                                               log_config=str(SOURCE / "log_conf.json"))
        server_class.assert_called_once_with(config=config)
        supervisor.assert_called_once_with(config, target=server_class.return_value.run, sockets=[socket])
        supervisor.return_value.run.assert_called_once_with()
        server_class.return_value.run.assert_not_called()
        config.load.assert_not_called()
        config.load_app.assert_not_called()
        self.assertTrue(socket.closed)

    def test_single_worker_is_supervised_without_loading_models_in_parent(self):
        self.launch()

    def test_configured_worker_count_is_preserved(self):
        self.launch(workers=3)

    def test_listener_is_closed_when_supervisor_fails(self):
        self.launch(failure=RuntimeError("supervisor failed"))


class IdlePolicyTests(unittest.TestCase):
    def setUp(self):
        self.tree = read_tree("main.py")
        names = {"update_state", "idle_shutdown_task"}
        nodes = [node for node in self.tree.body
                 if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names]
        self.namespace = dict(Iterator=object, time=SimpleNamespace(time=lambda: 1000),
                              active_requests=0, last_called=None,
                              lock=SimpleNamespace(locked=lambda: False),
                              settings=SimpleNamespace(model_ttl=300, model_ttl_poll_s=10),
                              log=Mock(), os=SimpleNamespace(kill=Mock(), getpid=lambda: 1234), signal=signal)
        # Do not import the ML stack or run real waits/signals in the policy tests.
        future = ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)
        exec(compile_nodes([future, *nodes], "main.py"), self.namespace)

    def poll(self, should_exit):
        class PollFinished(Exception):
            pass

        sleep = Mock()

        async def one_poll(seconds):
            sleep(seconds)
            raise PollFinished

        self.namespace["asyncio"] = SimpleNamespace(sleep=one_poll)
        if should_exit:
            asyncio.run(self.namespace["idle_shutdown_task"]())
            self.namespace["os"].kill.assert_called_once_with(1234, signal.SIGINT)
            sleep.assert_not_called()
        else:
            with self.assertRaises(PollFinished):
                asyncio.run(self.namespace["idle_shutdown_task"]())
            self.namespace["os"].kill.assert_not_called()
            sleep.assert_called_once_with(10)

    def test_never_used_worker_does_not_recycle(self):
        self.poll(False)

    def test_used_idle_worker_exits_to_release_native_memory(self):
        self.namespace["last_called"] = 699
        self.poll(True)

    def test_recent_and_exact_ttl_requests_do_not_exit(self):
        for last_called in (999, 700):
            with self.subTest(last_called=last_called):
                self.namespace["last_called"] = last_called
                self.poll(False)

    def test_active_request_and_model_load_prevent_exit(self):
        self.namespace["last_called"] = 1
        self.namespace["active_requests"] = 1
        self.poll(False)
        self.namespace["active_requests"] = 0
        self.namespace["lock"].locked = lambda: True
        self.poll(False)

    def test_request_state_is_released_even_on_failure(self):
        state = self.namespace["update_state"]()
        next(state)
        self.assertEqual(self.namespace["active_requests"], 1)
        self.assertEqual(self.namespace["last_called"], 1000)
        state.close()
        self.assertEqual(self.namespace["active_requests"], 0)

    def test_only_prediction_marks_the_worker_used(self):
        routes = {node.name: node for node in self.tree.body
                  if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
        self.assertIn("Depends(update_state)", ast.unparse(routes["predict"].decorator_list[0]))
        self.assertNotIn("update_state", ast.unparse(routes["ping"]))
        self.assertIn("settings.model_ttl > 0 and settings.model_ttl_poll_s > 0", ast.unparse(routes["lifespan"]))


if __name__ == "__main__":
    unittest.main()
