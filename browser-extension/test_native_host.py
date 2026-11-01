import io
import json
from pathlib import Path
import struct
import unittest
from unittest.mock import patch
import uuid

import native_host as host
from install_host import extension_id


class NativeHostTests(unittest.TestCase):
    def test_turkish_frame(self):
        request = {"action": "speak", "id": str(uuid.uuid4()), "text": "İyi günler. Şimdi okuyorum."}
        payload = json.dumps(request, ensure_ascii=False).encode()
        self.assertEqual(host.read_message(io.BytesIO(struct.pack("=I", len(payload)) + payload)), request)

    def test_bad_frames(self):
        for data in [b"", b"ab", struct.pack("=I", 0), struct.pack("=I", host.MAX_BYTES + 1),
                     struct.pack("=I", 8) + b"{}", struct.pack("=I", 1) + b"\xff"]:
            with self.subTest(data=data), self.assertRaises((ValueError, UnicodeError)):
                host.read_message(io.BytesIO(data))

    def test_commands(self):
        identifier = str(uuid.uuid4())
        for action in ["status", "stop", "pause", "resume"]:
            self.assertEqual(host.validate_request({"action": action, "id": identifier, "shell": "ignored"}),
                             {"action": action, "id": identifier})
        self.assertEqual(host.validate_request({"action": "speak", "id": identifier, "text": "  Şimdi.  "})["text"], "Şimdi.")
        self.assertEqual(len(host.validate_request({"action": "speak", "id": identifier, "text": "ş" * 30000})["text"]), 30000)

    def test_invalid_commands(self):
        identifier = str(uuid.uuid4())
        requests = [[], None, {"action": "shell", "id": identifier}, {"action": "stop", "id": 1},
                    {"action": "status", "id": "../../file"}]
        requests += [{"action": "speak", "id": identifier, "text": text} for text in [None, [], " ", "ş" * 30001]]
        for request in requests:
            with self.subTest(request=request), self.assertRaises(ValueError):
                host.validate_request(request)

    def test_origin_rejected_without_forwarding(self):
        output = io.BytesIO()
        with patch.object(Path, "read_text", return_value='"chrome-extension://allowed/"'), \
             patch.object(host.sys, "argv", ["host", "chrome-extension://foreign/"]), \
             patch.object(host.sys, "stdout") as stdout, patch.object(host, "forward") as forward:
            stdout.buffer = output
            host.main()
            forward.assert_not_called()
        self.assertFalse(host.read_message(io.BytesIO(output.getvalue()))["ok"])

    def test_stable_extension_identifier(self):
        manifest = json.loads(Path(__file__).with_name("chrome").joinpath("manifest.json").read_text())
        identifier = extension_id(manifest["key"])
        self.assertEqual(len(identifier), 32)
        self.assertTrue(all("a" <= char <= "p" for char in identifier))


if __name__ == "__main__":
    unittest.main()
