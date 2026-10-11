"""Local validation tests; these tests do not connect to a phone."""

import unittest
import uuid
from unittest.mock import patch

import ioaudio2_app_bridge as bridge


class BridgeRequestValidationTests(unittest.TestCase):
    def request(self, request_id):
        return {
            "schema": "audiorepeater_ioaudio2_request_v1",
            "requestID": request_id,
            "items": [{"itemKey": "sample", "fileName": "sample.wav",
                       "displayName": "Sample", "repeatCount": 1}],
        }

    def test_accepts_app_generated_uuid(self):
        bridge.validate_request(self.request(str(uuid.uuid4()).upper()))

    def test_rejects_request_ids_that_could_escape_run_directory(self):
        for request_id in ("../outside", "x/../../outside", "", 123, None):
            with self.subTest(request_id=request_id), self.assertRaises(ValueError):
                bridge.validate_request(self.request(request_id))

    def test_requires_explicit_safe_phone_host_before_preflight(self):
        for host in ("", "-oProxyCommand=anything", "phone;command", "phone\ncommand"):
            with self.subTest(host=host), patch.object(bridge, "PHONE_HOST", host):
                with self.assertRaisesRegex(ValueError, "AUDIOREPEATER_PHONE_HOST"):
                    bridge.preflight()


if __name__ == "__main__":
    unittest.main()
