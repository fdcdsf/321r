"""Смоук: первый вход и повторный запуск без изменения чужой настройки."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


script = Path(__file__).resolve().parents[1] / "scripts" / "pangolin-bootstrap.py"
spec = importlib.util.spec_from_file_location("pangolin_bootstrap", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeApi:
    def __init__(self, already=False):
        self.already = already
        self.orgs = []
        self.license_keys = []
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path))
        if path == "/auth/initial-setup-complete":
            return {"complete": self.already}
        if path == "/auth/set-server-admin":
            assert body["setupToken"] and body["password"]
            self.already = True
        if path == "/orgs":
            return self.orgs
        if path == "/license/keys":
            return self.license_keys
        if path == "/license/activate":
            self.license_keys.append({"active": True})
        if path == "/pick-org-defaults":
            return {"subnet": "100.90.0.0/16", "utilitySubnet": "100.96.0.0/16"}
        if path == "/org":
            self.orgs.append({"orgId": body["orgId"]})
        return None


class BootstrapTest(unittest.TestCase):
    def test_new_then_repeat(self):
        with tempfile.TemporaryDirectory() as td, patch.object(module, "setup_token", return_value="test-token"):
            api = FakeApi()
            secret = Path(td) / "admin.json"
            self.assertTrue(module.bootstrap(api, "admin@example.com", "cluster", secret))
            if os.name == "posix":
                self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
            before = secret.read_bytes()
            api.calls.clear()
            self.assertTrue(module.bootstrap(api, "admin@example.com", "cluster", secret))
            self.assertEqual(before, secret.read_bytes())
            self.assertNotIn(("PUT", "/auth/set-server-admin"), api.calls)
            self.assertNotIn(("PUT", "/org"), api.calls)

    def test_existing_admin_is_not_modified(self):
        with tempfile.TemporaryDirectory() as td:
            api = FakeApi(already=True)
            self.assertFalse(module.bootstrap(api, "admin@example.com", "cluster", Path(td) / "admin.json"))
            self.assertEqual(api.calls, [("GET", "/auth/initial-setup-complete")])

    def test_license_applied_only_once(self):
        with tempfile.TemporaryDirectory() as td, patch.object(module, "setup_token", return_value="test-token"):
            api = FakeApi()
            secret = Path(td) / "admin.json"
            license_file = Path(td) / "license.key"
            license_file.write_text("test-license", encoding="utf-8")
            module.bootstrap(api, "admin@example.com", "cluster", secret, license_file)
            module.bootstrap(api, "admin@example.com", "cluster", secret, license_file)
            self.assertEqual(api.calls.count(("POST", "/license/activate")), 1)


if __name__ == "__main__":
    unittest.main()
