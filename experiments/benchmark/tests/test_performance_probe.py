"""Fake snapshots and clocks only: never sample an actual application PID."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'tools' / 'performance_probe.py'
SPEC = importlib.util.spec_from_file_location('performance_probe', SCRIPT)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class FakeClock:
    def __init__(self):
        self.now = 100.0
        self.waits = []

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.waits.append(seconds)
        self.now += seconds


def snapshot(cpu, rss=100, executable='/Applications/Private Name.app/Contents/MacOS/App'):
    return {'cpuSeconds': cpu, 'rssKiB': rss, 'executable': executable}


class PerformanceProbeTests(unittest.TestCase):
    def run_probe(self, rows, duration=2, interval=1, overhead=0):
        timer = FakeClock()
        iterator = iter(rows)

        def read(pid):
            self.assertEqual(pid, 42)
            timer.now += overhead
            row = next(iterator)
            if isinstance(row, Exception):
                raise row
            return row

        return probe.probe(42, duration, interval, read, timer.clock, timer.sleep), timer

    def test_cpu_time_formats(self):
        for text, expected in [('0:00.00', 0), ('01:02.34', 62.34),
                               ('125:00.50', 7500.5), ('2:03:04', 7384),
                               ('1-02:03:04.50', 93784.5)]:
            with self.subTest(text=text):
                self.assertEqual(probe.cpu_seconds(text), expected)
        for text in ('nan', '-1:02', '0:60.00', '1:02:60', '1-02:03', '1:2', '1:02junk'):
            with self.subTest(text=text), self.assertRaises(probe.SnapshotError):
                probe.cpu_seconds(text)

    def test_whitespace_and_executable_path(self):
        row = probe.parse_snapshot('  42\t 02:03.45   2048   /Applications/My App.app/My  App  \n', 42)
        self.assertEqual(row, snapshot(123.45, 2048, '/Applications/My App.app/My  App'))
        for output in ('', '  \n', '42 0:00.00 10', '41 0:00.00 10 app',
                       '42 0:00.00 -1 app', '42 0:00.00 1 app\n42 0:00.00 1 app'):
            with self.subTest(output=output), self.assertRaises(probe.SnapshotError):
                probe.parse_snapshot(output, 42)

    def test_delta_cpu_not_lifetime_and_sampled_rss(self):
        report, timer = self.run_probe([snapshot(1000, 500), snapshot(1000.5, 700), snapshot(1002.5, 600)])
        self.assertEqual(report['status'], 'complete')
        self.assertEqual(report['cpuSingleCorePercent'], {'n': 2, 'p50': 125, 'p95': 192.5})
        self.assertEqual(report['rssKiB'], {'n': 3, 'max': 700})
        self.assertEqual(report['observedWallSeconds'], 2)
        self.assertEqual(timer.waits, [1, 1])
        self.assertNotIn('Private Name', json.dumps(report))

    def test_actual_wall_includes_snapshot_overhead(self):
        report, _ = self.run_probe([snapshot(10), snapshot(11)], duration=1, overhead=.5)
        self.assertAlmostEqual(report['observedWallSeconds'], 1.5)
        self.assertAlmostEqual(report['cpuSingleCorePercent']['p50'], 100 / 1.5)

    def test_interval_larger_than_duration_and_zero_cpu(self):
        report, timer = self.run_probe([snapshot(20), snapshot(20)], duration=1, interval=5)
        self.assertEqual(timer.waits, [1])
        self.assertEqual(report['status'], 'complete')
        self.assertEqual(report['cpuSingleCorePercent']['p95'], 0)

    def test_partial_failure_preserves_only_valid_samples(self):
        for final, reason in [(probe.SnapshotError('pid_missing'), 'pid_missing'),
                              (snapshot(12, 999, '/different'), 'executable_changed'),
                              (snapshot(9, 999), 'cpu_counter_regressed'),
                              (KeyboardInterrupt(), 'interrupted')]:
            with self.subTest(reason=reason):
                if isinstance(final, KeyboardInterrupt):
                    with patch.object(probe, 'read_snapshot'):
                        # KeyboardInterrupt derives from BaseException, not Exception.
                        timer = FakeClock()
                        reader = unittest.mock.Mock(side_effect=[snapshot(10), snapshot(11), final])
                        report = probe.probe(42, 2, 1, reader, timer.clock, timer.sleep)
                else:
                    report, _ = self.run_probe([snapshot(10), snapshot(11), final])
                self.assertEqual(report['status'], 'incomplete')
                self.assertEqual(report['reason'], reason)
                self.assertEqual(report['snapshotCount'], 2)
                self.assertEqual(report['rssKiB']['max'], 100)
                self.assertEqual(report['cpuSingleCorePercent']['n'], 1)

    def test_initial_failure_is_not_zero_usage(self):
        report, _ = self.run_probe([probe.SnapshotError('pid_missing')])
        self.assertEqual(report['status'], 'incomplete')
        self.assertIsNone(report['rssKiB']['max'])
        self.assertIsNone(report['cpuSingleCorePercent']['p50'])
        self.assertEqual(report['snapshotCount'], 0)

    def test_nonpositive_wall(self):
        reader = unittest.mock.Mock(side_effect=[snapshot(10), snapshot(11)])
        report = probe.probe(42, 1, 1, reader, lambda: 10, lambda _: None)
        self.assertEqual(report['reason'], 'nonpositive_wall_delta')

    def test_bounds(self):
        for pid, duration, interval in [(0, 1, 1), (-1, 1, 1), (True, 1, 1),
                                        (42, .99, 1), (42, 121, 1), (42, float('nan'), 1),
                                        (42, 1, .19), (42, 1, 5.1), (42, 1, float('inf'))]:
            with self.subTest(values=(pid, duration, interval)), self.assertRaises(ValueError):
                probe.validate(pid, duration, interval)
        probe.validate(42, 1, .2)
        probe.validate(42, 120, 5)

    def test_ps_exact_command_timeout_and_no_raw_output(self):
        result = subprocess.CompletedProcess([], 0, '42 0:01.00 256 /private/My App', '')
        with patch.object(probe.subprocess, 'run', return_value=result) as run:
            self.assertEqual(probe.read_snapshot(42)['rssKiB'], 256)
        args, kwargs = run.call_args
        self.assertEqual(args[0], ['/bin/ps', '-p', '42', '-o', 'pid=,time=,rss=,comm='])
        self.assertEqual(kwargs['timeout'], 2)
        self.assertNotIn('shell', kwargs)
        self.assertNotIn('%cpu', args[0][-1])
        for effect, reason in [(subprocess.TimeoutExpired('SECRET', 2), 'ps_timeout'),
                               (OSError('SECRET'), 'ps_unavailable')]:
            with patch.object(probe.subprocess, 'run', side_effect=effect):
                with self.assertRaisesRegex(probe.SnapshotError, '^' + reason + '$'):
                    probe.read_snapshot(42)
        with patch.object(probe.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'SECRET')):
            with self.assertRaisesRegex(probe.SnapshotError, '^pid_missing_or_ps_failed$'):
                probe.read_snapshot(42)

    def test_cli_no_discovery_or_real_sampling(self):
        with patch.object(probe, 'probe') as sample, contextlib.redirect_stderr(io.StringIO()):
            for args in ([], ['--pid', '0', '--duration', '1'],
                         ['--pid', '42', '--duration', 'nan']):
                with self.assertRaises(SystemExit) as error:
                    probe.main(args)
                self.assertEqual(error.exception.code, 2)
            sample.assert_not_called()
        for status, code in [('complete', 0), ('incomplete', 2)]:
            with patch.object(probe.sys, 'platform', 'darwin'), patch.object(probe, 'probe', return_value={'status': status}) as sample:
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(probe.main(['--pid', '42', '--duration', '1']), code)
                sample.assert_called_once_with(42, 1, 1)
                self.assertEqual(json.loads(output.getvalue())['status'], status)
        with patch.object(probe.sys, 'platform', 'linux'), patch.object(probe, 'probe') as sample:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(probe.main(['--pid', '42', '--duration', '1']), 2)
            sample.assert_not_called()


if __name__ == '__main__':
    unittest.main()
