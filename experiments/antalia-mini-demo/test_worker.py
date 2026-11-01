import importlib.util
import json
from pathlib import Path
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import Mock, patch

WORKER = Path(__file__).resolve().parents[2] / "Sources/VoiceTypingCore/Resources/ReadAloud/antalia_worker.py"
spec = importlib.util.spec_from_file_location("antalia_worker", WORKER)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def request(self, text, identifier=None):
        return json.dumps({"id": identifier or str(uuid.uuid4()), "text": text})

    def test_valid_request_preserves_turkish(self):
        identifier = str(uuid.uuid4()).upper()
        actual_id, text = worker.request_from_line(self.request("  Öğrenci şiiri okuyor.\n", identifier))
        self.assertEqual(actual_id, identifier.lower())
        self.assertEqual(text, "Öğrenci şiiri okuyor.")

    def test_character_limit(self):
        self.assertEqual(len(worker.request_from_line(self.request("ş" * 5000))[1]), 5000)
        with self.assertRaises(ValueError):
            worker.request_from_line(self.request("ş" * 5001))

    def test_empty_text(self):
        with self.assertRaises(ValueError):
            worker.request_from_line(self.request(" \n\t"))

    def test_invalid_id(self):
        with self.assertRaises(ValueError):
            worker.request_from_line(self.request("Merhaba", "../../private"))

    def test_invalid_request_types(self):
        for value in [[], None, {}, {"id": 1, "text": "x"}, {"id": str(uuid.uuid4()), "text": 123}]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                worker.request_from_line(json.dumps(value))

    def test_invalid_json(self):
        with self.assertRaises(ValueError):
            worker.request_from_line("not-json")

    def model_modules(self, mps=True):
        torch = SimpleNamespace(set_num_threads=Mock(),
                                backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: mps)))
        model = Mock()
        antalia = SimpleNamespace(Antalia=Mock(return_value=model))
        hub = SimpleNamespace(snapshot_download=Mock(return_value="/local/model"))
        return {"torch": torch, "antalia_mini": antalia, "huggingface_hub": hub}

    def test_offline_load_uses_local_snapshot(self):
        modules = self.model_modules()
        with patch.dict("sys.modules", modules), patch.dict(worker.os.environ):
            model, device = worker.load_model()
            self.assertEqual(worker.os.environ["HF_HUB_OFFLINE"], "1")
        self.assertEqual(device, "mps")
        modules["huggingface_hub"].snapshot_download.assert_called_once_with(
            worker.MODEL_REPO, revision=worker.MODEL_REVISION, local_files_only=True,
            allow_patterns=["config.json", "acoustic.safetensors", "vocoder.safetensors"])
        modules["antalia_mini"].Antalia.assert_called_once_with(model="/local/model", device="mps", threads=2)
        model.say.assert_called_once()

    def test_prepare_allows_download(self):
        modules = self.model_modules(mps=False)
        with patch.dict("sys.modules", modules):
            _, device = worker.load_model(offline=False)
        self.assertEqual(device, "cpu")
        self.assertFalse(modules["huggingface_hub"].snapshot_download.call_args.kwargs["local_files_only"])

    def test_mps_failure_falls_back_to_cpu(self):
        modules = self.model_modules()
        modules["antalia_mini"].Antalia.side_effect = [RuntimeError("MPS unavailable"), Mock()]
        with patch.dict("sys.modules", modules), patch.dict(worker.os.environ):
            _, device = worker.load_model()
        self.assertEqual(device, "cpu")
        self.assertEqual([call.kwargs["device"] for call in modules["antalia_mini"].Antalia.call_args_list],
                         ["mps", "cpu"])

    def test_missing_snapshot_never_constructs_model(self):
        modules = self.model_modules()
        modules["huggingface_hub"].snapshot_download.side_effect = FileNotFoundError("missing weights")
        with patch.dict("sys.modules", modules), patch.dict(worker.os.environ), self.assertRaises(FileNotFoundError):
            worker.load_model()
        modules["antalia_mini"].Antalia.assert_not_called()

    def test_cpu_failure_is_reported(self):
        modules = self.model_modules(mps=False)
        modules["antalia_mini"].Antalia.side_effect = RuntimeError("load failure")
        with patch.dict("sys.modules", modules), patch.dict(worker.os.environ), self.assertRaises(RuntimeError):
            worker.load_model()
        self.assertEqual(modules["antalia_mini"].Antalia.call_count, 1)


if __name__ == "__main__":
    unittest.main()
