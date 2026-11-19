"""Два режима Remnawave используют один API; vpn-host остаётся на своей ноде."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1] / "scripts"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bootstrap = load("remnawave-bootstrap.py")
mask = load("remnawave-mask.py")


class FakeApi:
    def __init__(self):
        self.profiles = []
        self.hosts = []
        self.squads = []
        self.users = []

    def call(self, path, method="GET", data=None, browser=False):
        if path == "/config-profiles":
            if method == "POST":
                self.profiles.append({"name": data["name"], "uuid": "profile-uuid"})
                return self.profiles[-1]
            return {"configProfiles": list(self.profiles)}
        if path.endswith("/inbounds"):
            return {"inbounds": [{"tag": "masked-vless", "uuid": "inbound-uuid"}]}
        if path == "/nodes":
            return [{"name": "node-a", "uuid": "node-a-uuid"},
                    {"name": "node-b", "uuid": "node-b-uuid"}]
        if path == "/hosts":
            if method == "POST":
                self.hosts.append(data)
                return data
            return list(self.hosts)
        if path == "/internal-squads":
            if method == "POST":
                self.squads.append({"name": data["name"], "uuid": "squad-uuid"})
                return self.squads[-1]
            return {"internalSquads": list(self.squads)}
        if path == "/users":
            if method == "POST":
                self.users.append({"username": data["username"], "shortUuid": "test-short"})
                return self.users[-1]
            return {"users": list(self.users)}
        raise AssertionError(path)


class ProvisionTest(unittest.TestCase):
    def test_profile_hosts_squad_repeat(self):
        api = FakeApi()
        bootstrap.ensure_profile(api)
        bootstrap.ensure_profile(api)
        self.assertEqual(len(api.profiles), 1)
        self.assertEqual(mask.ensure(api, "example.com", ["a", "b"]), "test-short")
        mask.ensure(api, "example.com", ["a", "b"])
        self.assertEqual(len(api.hosts), 2)
        self.assertEqual(len(api.squads), 1)
        self.assertEqual(len(api.users), 1)
        self.assertEqual({h["address"]: h["nodes"] for h in api.hosts}, {
            "vpn-a.example.com": ["node-a-uuid"], "vpn-b.example.com": ["node-b-uuid"]})

    def test_connect_uses_token_without_local_registration(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "api.token"
            path.write_text("test-api-token", encoding="utf-8")
            api = bootstrap.Api("https://rem.example.com")
            bootstrap.admin(api, "connect", "not-used.json", path)
            self.assertEqual(api.token, "test-api-token")
            self.assertTrue(api.api_token)


if __name__ == "__main__":
    unittest.main()
