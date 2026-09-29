import sys
import threading
import unittest
from unittest.mock import patch
from http.client import HTTPConnection
import json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "application"))
from app import Handler, ThreadingHTTPServer  # noqa: E402


class AppTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def get(self, path):
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        connection.request("GET", path)
        response = connection.getresponse()
        return response.status, response.read().decode()

    def test_endpoints(self):
        version = (Path(__file__).parents[1] / "application" / "VERSION").read_text().strip()
        self.assertEqual(self.get("/health"), (200, "OK\n"))
        self.assertEqual(self.get("/version"), (200, f"{version}\n"))
        status, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn("LXC APPLIANCE POC", body)
        self.assertIn("OPERATIONAL", body)
        self.assertIn("GITHUB UPDATE OK", body)
        self.assertIn("Vérifier les mises à jour", body)
        with patch("app.latest_release", return_value="9.9.9"):
            status, body = self.get("/check-update")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {
            "current": version,
            "latest": "9.9.9",
            "update_available": True,
        })
        self.assertEqual(self.get("/missing")[0], 404)


if __name__ == "__main__":
    unittest.main()
