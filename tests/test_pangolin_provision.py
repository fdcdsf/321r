"""Идемпотентность сайтов и HTTP-ресурсов Pangolin без сетевых запросов."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


def module(name):
    path = Path(__file__).resolve().parents[1] / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


sites_module = module("pangolin-sites.py")
resources_module = module("pangolin-resources.py")


class FakeApi:
    def __init__(self):
        self.sites = []
        self.resources = []
        self.targets = []
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path))
        if path.endswith("/sites"):
            return {"sites": list(self.sites)}
        if path.endswith("/site") and method == "PUT":
            new = {"siteId": len(self.sites) + 1, "niceId": body["niceId"],
                   "newtId": "id123", "secret": "secret123", "online": True}
            self.sites.append(new)
            return new
        if path.endswith("/domains"):
            return {"domains": [{"domainId": "domain", "baseDomain": "example.com", "verified": True}]}
        if path.endswith("/resources"):
            return {"resources": list(self.resources)}
        if path.endswith("/resource") and method == "PUT":
            new = {"resourceId": 1, "fullDomain": body["subdomain"] + ".example.com"}
            self.resources.append(new)
            return new
        if path.endswith("/targets"):
            return {"targets": self.targets}
        if path.endswith("/target") and method == "PUT":
            self.targets.append(body)
            return body
        raise AssertionError((method, path))


class ProvisionTest(unittest.TestCase):
    def test_sites_no_duplicate_and_secret_not_regenerated(self):
        with tempfile.TemporaryDirectory() as td:
            api = FakeApi()
            sites_module.ensure_sites(api, "cluster", "https://pangolin.example.com", ["a"], td)
            path = Path(td) / "newt-a.env"
            first = path.read_bytes()
            sites_module.ensure_sites(api, "cluster", "https://pangolin.example.com", ["a"], td)
            self.assertEqual(path.read_bytes(), first)
            self.assertEqual(len(api.sites), 1)

    def test_existing_site_without_secret_refuses_to_overwrite(self):
        with tempfile.TemporaryDirectory() as td:
            api = FakeApi()
            api.sites.append({"siteId": 1, "niceId": "cluster-a", "online": True})
            with self.assertRaises(sites_module.bootstrap.ApiError):
                sites_module.ensure_sites(api, "cluster", "https://pangolin.example.com", ["a"], td)

    def test_resource_and_target_are_idempotent(self):
        api = FakeApi()
        api.sites.append({"siteId": 1, "niceId": "cluster-b", "online": True})
        args = (api, "cluster", "example.com", ["komodo:b:127.0.0.1:9120:http:9120:/"])
        resources_module.ensure_resources(*args)
        resources_module.ensure_resources(*args)
        self.assertEqual(len(api.resources), 1)
        self.assertEqual(len(api.targets), 1)
        self.assertTrue(api.targets[0]["hcEnabled"])


if __name__ == "__main__":
    unittest.main()
