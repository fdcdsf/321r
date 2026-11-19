"""Отдельный токен красивой страницы создаётся один раз и не показывается."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


path = Path(__file__).resolve().parents[1] / "scripts" / "remnawave-subpage.py"
spec = importlib.util.spec_from_file_location("remnawave_subpage", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeApi:
    def __init__(self):
        self.created = 0

    def call(self, route, method="GET", data=None, browser=False):
        if route == "/tokens" and method == "GET":
            return {"tokens": []}
        if route == "/tokens" and method == "POST":
            self.created += 1
            assert data["scopes"] == ["*"]
            return {"token": "test-secret"}
        raise AssertionError((route, method))


class SubpageTest(unittest.TestCase):
    def test_token_created_once(self):
        with tempfile.TemporaryDirectory() as td, patch.object(module, "run") as runner:
            api = FakeApi()
            token_path = str(Path(td) / "token")
            module.provision(api, "10.66.0.2", "key", "compose", token_path)
            module.provision(api, "10.66.0.2", "key", "compose", token_path)
            self.assertEqual(api.created, 1)
            self.assertEqual(Path(token_path).read_text().strip(), "test-secret")
            self.assertEqual(runner.call_count, 10)


if __name__ == "__main__":
    unittest.main()
