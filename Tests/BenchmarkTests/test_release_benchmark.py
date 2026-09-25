"""Synthetic fixtures test the evaluator, not actual speech/device performance."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools' / 'release_benchmark.py'
SPEC = importlib.util.spec_from_file_location('release_benchmark', SCRIPT)
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


class ReleaseBenchmarkTests(unittest.TestCase):
    def fixture(self):
        manifest = {'devices': ['dahili', 'headset'], 'cases': []}
        speech, latency = [], []
        for device in manifest['devices']:
            for category in benchmark.CATEGORIES:
                case_id = device + '-' + category
                manifest['cases'].append({'id': case_id, 'device': device, 'category': category})
                text = '' if category in ('silence', 'noise') else 'İYİ ÇALIŞIYOR'
                speech.append({'id': case_id, 'reference': text, 'hypothesis': text})
                latency.append({'id': case_id, 'hudMs': 100, 'firstInterimMs': 500,
                                'releaseToFinalMs': 1000})
        return manifest, speech, latency

    def report(self, data=None, **kwargs):
        return benchmark.evaluate(*(data or self.fixture()),
                                  thresholds=kwargs.pop('thresholds', dict(hudMs=150, firstInterimMs=1200,
                                                                           releaseToFinalMs=2000, werPercent=10)),
                                  real_measurements=kwargs.pop('real_measurements', True), **kwargs)

    def test_turkish_normalization_and_unicode_punctuation(self):
        self.assertEqual(benchmark.word_errors('IŞIK, İYİ… “ÇÖĞÜŞ”!', 'ışık iyi çöğüş'), (0, 3, 0))
        self.assertEqual(benchmark.normalize('I\u0307Yİ'), ['iyi'])
        self.assertEqual(benchmark.word_errors('I', 'i'), (1, 1, 0))
        self.assertEqual(benchmark.word_errors('bir iki üç', 'bir dört'), (2, 3, 0))

    def test_empty_reference(self):
        self.assertEqual(benchmark.word_errors('', ''), (0, 0, 0))
        self.assertEqual(benchmark.word_errors('', 'uydurma iki'), (2, 0, 2))
        self.assertEqual(benchmark.word_errors('bir iki', ''), (2, 2, 0))
        data = self.fixture()
        data[1][6]['hypothesis'] = 'uydurma'
        report = self.report(data)
        self.assertEqual(report['status'], 'fail')
        self.assertEqual(report['groups'][6]['hallucinatedWords'], 1)
        self.assertIsNone(report['groups'][6]['werPercent'])

    def test_complete_and_device_grouping(self):
        report = self.report()
        self.assertEqual(report['status'], 'pass')
        self.assertEqual(len(report['groups']), 16)
        self.assertFalse(report['groups'][6]['latency']['firstInterimMs']['applicable'])
        data = self.fixture()
        data[2][8]['hudMs'] = 151
        self.assertEqual(self.report(data)['failures'], ['headset/normal: hudMs p95 exceeds threshold'])

    def test_weighted_aggregation_and_order_invariance(self):
        data = self.fixture()
        data[1][0].update(reference='bir', hypothesis='yanlış')
        data[0]['cases'].append({'id': 'long', 'device': 'dahili', 'category': 'normal'})
        data[1].append({'id': 'long', 'reference': 'iki üç dört beş altı yedi sekiz dokuz on',
                        'hypothesis': 'iki üç dört beş altı yedi sekiz dokuz on'})
        data[2].append({'id': 'long', 'hudMs': 140, 'firstInterimMs': 700, 'releaseToFinalMs': 1500})
        report = self.report(data)
        group = report['groups'][0]
        self.assertEqual(group['werPercent'], 10)
        self.assertEqual(group['latency']['hudMs']['p50'], 120)
        self.assertEqual(group['latency']['hudMs']['p95'], 138)
        for rows in (data[0]['cases'], data[1], data[2]):
            rows.reverse()
        self.assertEqual(report, self.report(data))

    def test_percentiles(self):
        self.assertIsNone(benchmark.percentile([], .95))
        self.assertEqual(benchmark.percentile([12], .95), 12)
        self.assertAlmostEqual(benchmark.percentile([40, 10, 30, 20], .95), 38.5)

    def test_missing_and_invalid_metrics_never_pass(self):
        for value in (None, True, False, '100', -1, float('nan'), float('inf')):
            with self.subTest(value=value):
                data = self.fixture()
                data[2][0]['hudMs'] = value
                self.assertEqual(self.report(data)['status'], 'not-ready')
        data = self.fixture()
        data[2].clear()
        self.assertEqual(self.report(data)['status'], 'not-ready')
        self.assertEqual(self.report(thresholds={})['status'], 'not-ready')
        self.assertEqual(self.report(real_measurements=False)['status'], 'not-ready')

    def test_missing_coverage_and_speech(self):
        data = self.fixture()
        data[1].pop()
        self.assertEqual(self.report(data)['status'], 'not-ready')
        self.assertEqual(self.report(minimum=2)['status'], 'not-ready')
        self.assertEqual(self.report(({'devices': ['dahili'], 'cases': []}, [], []))['status'], 'not-ready')
        data = self.fixture()
        data[1][0]['reference'] = ''
        self.assertEqual(self.report(data)['status'], 'not-ready')
        data = self.fixture()
        data[1][0].pop('hypothesis')
        self.assertEqual(self.report(data)['status'], 'not-ready')

    def test_duplicate_and_unknown_ids_rejected(self):
        data = self.fixture()
        data[1].append(data[1][0])
        with self.assertRaises(ValueError):
            self.report(data)
        data = self.fixture()
        data[2].append({'id': 'unknown'})
        with self.assertRaises(ValueError):
            self.report(data)

    def test_read_only_actual_log_format_no_transcript_leak_or_invented_metrics(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input.log'
            text = ('private transcript MUST_NOT_LEAK\n'
                    '2026-09-15 notice [RecordLatency] provider=apple model=tr-TR '
                    'keyEntry=0ms preparingPresented=20ms hudRunLoopYield=24ms '
                    'recorderStarted=100ms firstInterim=650ms end=firstInterim\n'
                    '[RecordLatency] provider=apple model=tr-TR keyEntry=0ms end=stop\n')
            path.write_text(text, encoding='utf-8')
            cases = {'a': {'id': 'a', 'record_latency_line': 2},
                     'b': {'id': 'b', 'record_latency_line': 3}}
            rows = benchmark.import_log(path, cases)
            self.assertEqual(rows[0], {'id': 'a', 'firstInterimMs': 650,
                                      'preparingPresentedMs': 20, 'hudRunLoopYieldMs': 24})
            self.assertEqual(rows[1], {'id': 'b'})
            self.assertEqual(path.read_text(encoding='utf-8'), text)
            self.assertNotIn('MUST_NOT_LEAK', json.dumps(rows))

    def test_cli_exit_codes_and_private_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, speech, latency = self.fixture()
            paths = [root / name for name in ('manifest.json', 'speech.jsonl', 'latency.json', 'thresholds.json')]
            paths[0].write_text(json.dumps(manifest), encoding='utf-8')
            paths[1].write_text('\n'.join(json.dumps(r) for r in speech), encoding='utf-8')
            paths[2].write_text(json.dumps(latency), encoding='utf-8')
            paths[3].write_text(json.dumps(dict(hudMs=150, firstInterimMs=1200,
                                               releaseToFinalMs=2000, werPercent=10)), encoding='utf-8')
            args = ['--manifest', str(paths[0]), '--speech', str(paths[1]), '--latency', str(paths[2]),
                    '--thresholds', str(paths[3])]
            for extra, expected in (([], 2), (['--attest-real-measurements'], 0)):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(benchmark.main(args + extra), expected)
                self.assertNotIn('İYİ', output.getvalue())
            latency[0]['hudMs'] = 999
            paths[2].write_text(json.dumps(latency), encoding='utf-8')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(benchmark.main(args + ['--attest-real-measurements']), 1)
            paths[1].write_text('MUST_NOT_LEAK invalid json', encoding='utf-8')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(benchmark.main(args), 2)
            self.assertNotIn('MUST_NOT_LEAK', output.getvalue())


if __name__ == '__main__':
    unittest.main()
