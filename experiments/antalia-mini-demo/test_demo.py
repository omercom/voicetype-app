import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import demo


class DemoTests(unittest.TestCase):
    def test_metrics(self):
        result = demo.metrics(0.5, 5, 0.1)
        self.assertEqual(result["generation_ms"], 500)
        self.assertEqual(result["first_chunk_ms"], 100)
        self.assertEqual(result["rtf"], 0.1)
        self.assertEqual(result["realtime_factor"], 10)

    def test_invalid_durations(self):
        for elapsed, duration in [(0, 1), (1, 0), (-1, 1)]:
            with self.assertRaises(ValueError):
                demo.metrics(elapsed, duration)

    def test_text_inputs(self):
        self.assertEqual(demo.load_texts(demo.parse_args(["--text", "  Merhaba.  "])), ["Merhaba."])
        self.assertEqual(len(demo.load_texts(demo.parse_args([]))), 8)
        with self.assertRaises(ValueError):
            demo.load_texts(demo.parse_args(["--text", " "]))
        with self.assertRaises(ValueError):
            demo.load_texts(demo.parse_args(["--text", "a" * 10001]))

    def test_utf8_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "text.txt"
            path.write_text("Türkçe: ışık, çığ, öğün.", encoding="utf-8")
            self.assertEqual(demo.load_texts(demo.parse_args(["--file", str(path)])),
                             ["Türkçe: ışık, çığ, öğün."])

    def test_invalid_run_count(self):
        with self.assertRaises(SystemExit), patch("sys.stderr"):
            demo.parse_args(["--runs", "0"])

    def test_say_timing(self):
        speech = SimpleNamespace(duration=5)
        tts = SimpleNamespace(say=lambda text, seed: speech)
        with patch("demo.time.perf_counter", side_effect=[10, 10.5]):
            result, output = demo.measure_say(tts, "Merhaba")
        self.assertIs(output, speech)
        self.assertEqual(result["generation_ms"], 500)

    def test_stream_first_chunk_and_duration(self):
        tts = SimpleNamespace(stream=lambda text, **kwargs: iter([[], [0] * 10, [0] * 30]))
        with patch("demo.time.perf_counter", side_effect=[10, 10.1, 10.5]):
            result = demo.measure_stream(tts, "Merhaba", rate=10)
        self.assertAlmostEqual(result["first_chunk_ms"], 100)
        self.assertEqual(result["audio_seconds"], 4)
        self.assertEqual(result["chunks"], 2)

    def test_empty_stream(self):
        tts = SimpleNamespace(stream=lambda text, **kwargs: iter([]))
        with self.assertRaises(ValueError):
            demo.measure_stream(tts, "Merhaba")


if __name__ == "__main__":
    unittest.main()
