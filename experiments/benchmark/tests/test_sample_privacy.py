import asyncio
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


BENCHMARK_DIR = Path(__file__).resolve().parents[1]


def load_module(name, filename, dependencies):
    spec = importlib.util.spec_from_file_location(name, BENCHMARK_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, dependencies):
        spec.loader.exec_module(module)
    return module


class SamplePrivacyTests(unittest.TestCase):
    def test_checked_in_metadata_has_no_machine_paths(self):
        metadata = json.loads((BENCHMARK_DIR / "samples" / "samples_metadata.json").read_text(encoding="utf-8"))
        self.assertTrue(metadata)
        for sample in metadata:
            self.assertNotIn("filepath", sample)
            self.assertEqual(os.path.basename(sample["filename"]), sample["filename"])

    def test_generated_samples_and_custom_audio_resolve_independently(self):
        runner = load_module("benchmark_runner_for_test", "run_benchmark.py", {"jiwer": types.ModuleType("jiwer")})
        base = os.path.join("root", "benchmark")
        self.assertEqual(
            runner.sample_audio_path({"filename": "example.mp3", "filepath": "/old/private/path.mp3"}, base),
            os.path.join(base, "samples", "example.mp3"),
        )
        self.assertEqual(runner.sample_audio_path({"filepath": "my-audio.mp3"}, base), "my-audio.mp3")
        self.assertEqual(runner.sample_audio_path({"filepath": "/tmp/my-audio.mp3"}, base), "/tmp/my-audio.mp3")

    def test_generator_does_not_store_absolute_audio_paths(self):
        fake_edge_tts = types.ModuleType("edge_tts")

        class FakeCommunicate:
            def __init__(self, **kwargs):
                pass

            async def save(self, path):
                pass

        fake_edge_tts.Communicate = FakeCommunicate
        generator = load_module("benchmark_generator_for_test", "generate_samples.py", {"edge_tts": fake_edge_tts})
        with tempfile.TemporaryDirectory() as directory:
            generator.SAMPLES_DIR = directory
            generator.METADATA_FILE = os.path.join(directory, "samples_metadata.json")
            with contextlib.redirect_stdout(io.StringIO()):
                asyncio.run(generator.generate_all())
            with open(generator.METADATA_FILE, encoding="utf-8") as file:
                metadata = json.load(file)
        self.assertEqual(len(metadata), len(generator.TEST_CASES))
        for sample in metadata:
            self.assertNotIn("filepath", sample)
            self.assertEqual(os.path.basename(sample["filename"]), sample["filename"])


if __name__ == "__main__":
    unittest.main()
