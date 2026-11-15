import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from mitmproxy import http


class AddonTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="agy-addon-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        source = Path(__file__).resolve().parents[1] / "addon.py"
        spec = importlib.util.spec_from_file_location("region_addon", source)
        self.addon = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.addon)
        self.addon.LOG = str(self.root / "mitm.log")
        self.addon.VERBOSE_FLAG = str(self.root / "verbose.flag")

    def flow(self, body, host="daily-cloudcode-pa.googleapis.com"):
        content = json.dumps(body).encode() if isinstance(body, dict) else body
        return SimpleNamespace(
            request=http.Request.make("POST", f"https://{host}/v1internal:loadCodeAssist"),
            response=http.Response.make(200, content, {"content-type": "application/json"}),
        )

    def test_location_response_preserves_tier_project_and_quota(self):
        body = {
            "currentTier": {"id": "standard-tier"},
            "allowedTiers": [{"id": "standard-tier", "isDefault": True}],
            "ineligibleTiers": [{
                "reasonCode": "UNSUPPORTED_LOCATION",
                "reasonMessage": "Not currently available in your location.",
                "tierId": "free-tier",
            }],
            "cloudaicompanionProject": "synthetic-project",
            "paidTier": {"id": "synthetic-paid-tier"},
        }
        flow = self.flow(body)
        self.addon.response(flow)
        expected = dict(body, ineligibleTiers=[])
        self.assertEqual(json.loads(flow.response.get_text()), expected)
        self.assertIn("CLEANED", Path(self.addon.LOG).read_text())

    def test_other_hosts_are_not_rewritten(self):
        for host in ("example.com", "googleapis.com.example.com"):
            with self.subTest(host=host):
                flow = self.flow({"ineligibleTiers": [{"tierId": "free-tier"}]}, host)
                original = flow.response.content
                self.addon.response(flow)
                self.assertEqual(flow.response.content, original)

    def test_non_json_bodies_are_not_rewritten(self):
        for body in (b"ineligibleTiers: not-json", b"\xff\xfeineligibleTiers"):
            with self.subTest(body=body):
                flow = self.flow(body)
                self.addon.response(flow)
                self.assertEqual(flow.response.content, body)

    def test_nested_snake_case_field_is_cleaned(self):
        flow = self.flow({"result": {"ineligible_tiers": [{"tier_id": "free-tier"}], "keep": 1}})
        self.addon.response(flow)
        self.assertEqual(json.loads(flow.response.get_text()), {
            "result": {"ineligible_tiers": [], "keep": 1},
        })

    def test_verbose_flag_is_dynamic_and_hides_message_values(self):
        body = {
            "reasonCode": "UNSUPPORTED_LOCATION",
            "tierId": "free-tier",
            "reasonMessage": "synthetic-user@example.com is ineligible",
            "validationErrorMessage": "synthetic-private-diagnostic",
            "token": "synthetic-token",
        }
        flow = self.flow(body)
        self.addon.response(flow)
        log = Path(self.addon.LOG)
        self.assertFalse(log.exists())
        flag = Path(self.addon.VERBOSE_FLAG)
        flag.touch()
        self.addon.response(flow)
        text = log.read_text()
        self.assertIn("SHAPE", text)
        self.assertIn("UNSUPPORTED_LOCATION", text)
        self.assertIn("free-tier", text)
        self.assertNotIn("synthetic-user@example.com", text)
        self.assertNotIn("synthetic-private-diagnostic", text)
        self.assertNotIn("synthetic-token", text)
        flag.unlink()
        self.addon.response(flow)
        self.assertEqual(log.read_text(), text)


if __name__ == "__main__":
    unittest.main()
