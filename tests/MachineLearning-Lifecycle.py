"""Dependency-free checks against the prepared, pinned Immich source."""

import ast
import asyncio
import signal
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


SOURCE = Path(sys.argv.pop(1)) / "machine-learning" / "immich_ml"


def read_tree(name):
    return ast.parse((SOURCE / name).read_text(encoding="utf-8"))


def compile_nodes(nodes, filename):
    return compile(ast.fix_missing_locations(ast.Module(body=nodes, type_ignores=[])), filename, "exec")


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
        uvicorn = SimpleNamespace(Config=Mock(return_value=config))
        server_class = Mock()
        supervisor = Mock()
        supervisor.return_value.run.side_effect = failure
        namespace = dict(non_prefixed_settings=SimpleNamespace(immich_host="[::1]", immich_port=3210),
                         settings=SimpleNamespace(workers=workers, http_keepalive_timeout_s=7),
                         module_dir=SOURCE, __package__="immich_ml")
        with patch.dict(sys.modules, {"uvicorn": uvicorn,
                                     "uvicorn.supervisors": SimpleNamespace(Multiprocess=supervisor),
                                     "immich_ml.config": SimpleNamespace(CustomUvicornServer=server_class)}):
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
