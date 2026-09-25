#!/usr/bin/env python3
"""Read-only macOS CPU/RSS sampling for one explicitly supplied PID."""
import argparse
import json
import math
import re
import subprocess
import sys
import time

PS_TIMEOUT = 2.0


class SnapshotError(Exception):
    """Only fixed, non-sensitive reason codes are exposed in reports."""


def cpu_seconds(text):
    # Darwin commonly prints minutes:seconds.hundredths; also accept h:m:s
    # and day-h:m:s without confusing a long minute count with hours.
    match = re.fullmatch(r'(?:(\d+)-)?(\d+):(\d{2})(?::(\d{2}))?(\.\d+)?', text)
    if not match:
        raise SnapshotError('invalid_cpu_time')
    days, first, second, third, fraction = match.groups()
    if int(second) >= 60 or (third is not None and int(third) >= 60) or (days and third is None):
        raise SnapshotError('invalid_cpu_time')
    if third is None:
        total = int(first) * 60 + int(second)
    else:
        total = int(days or 0) * 86400 + int(first) * 3600 + int(second) * 60 + int(third)
    try:
        value = total + float(fraction or 0)
    except OverflowError:
        raise SnapshotError('invalid_cpu_time') from None
    if not math.isfinite(value):
        raise SnapshotError('invalid_cpu_time')
    return value


def parse_snapshot(output, pid):
    lines = [line for line in output.splitlines() if line.strip()]
    if not lines:
        raise SnapshotError('pid_missing')
    if len(lines) != 1:
        raise SnapshotError('invalid_ps_output')
    fields = lines[0].strip().split(None, 3)
    if len(fields) != 4 or not fields[0].isdigit() or not fields[2].isdigit():
        raise SnapshotError('invalid_ps_output')
    if int(fields[0]) != pid:
        raise SnapshotError('pid_mismatch')
    return {'cpuSeconds': cpu_seconds(fields[1]), 'rssKiB': int(fields[2]),
            'executable': fields[3]}


def read_snapshot(pid):
    try:
        result = subprocess.run(
            ['/bin/ps', '-p', str(pid), '-o', 'pid=,time=,rss=,comm='],
            capture_output=True, text=True, timeout=PS_TIMEOUT, check=False,
            env={'LC_ALL': 'C', 'PATH': '/usr/bin:/bin'})
    except subprocess.TimeoutExpired:
        raise SnapshotError('ps_timeout') from None
    except (OSError, UnicodeError):
        raise SnapshotError('ps_unavailable') from None
    if result.returncode != 0:
        raise SnapshotError('pid_missing_or_ps_failed')
    return parse_snapshot(result.stdout, pid)


def validate(pid, duration, interval):
    if type(pid) is not int or pid <= 0:
        raise ValueError('pid must be a positive integer')
    for name, value, lower, upper in (('duration', duration, 1, 120), ('interval', interval, .2, 5)):
        if type(value) not in (int, float) or not math.isfinite(value) or not lower <= value <= upper:
            raise ValueError(name + ' outside allowed range')


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def probe(pid, duration, interval, snapshot=read_snapshot, clock=time.monotonic, sleep=time.sleep):
    validate(pid, duration, interval)
    rates, rss, elapsed_intervals = [], [], []
    reason = None
    started = previous_time = None
    try:
        previous = snapshot(pid)
        started = previous_time = clock()
        rss.append(previous['rssKiB'])
        deadline = started + duration
        while previous_time < deadline:
            # Last wait is shortened to reach the requested duration even when
            # interval exceeds duration. Each ps call has its own hard timeout.
            sleep(max(0, min(interval, deadline - clock())))
            current = snapshot(pid)
            now = clock()
            if current['executable'] != previous['executable']:
                raise SnapshotError('executable_changed')
            wall = now - previous_time
            delta = current['cpuSeconds'] - previous['cpuSeconds']
            if wall <= 0:
                raise SnapshotError('nonpositive_wall_delta')
            if delta < 0:
                raise SnapshotError('cpu_counter_regressed')
            rates.append(100 * delta / wall)
            elapsed_intervals.append(wall)
            rss.append(current['rssKiB'])
            previous, previous_time = current, now
    except SnapshotError as error:
        reason = str(error)
    except KeyboardInterrupt:
        reason = 'interrupted'
    if not rates and reason is None:
        reason = 'insufficient_snapshots'
    return {
        'status': 'incomplete' if reason else 'complete',
        'reason': reason,
        'pid': pid,
        'requestedDurationSeconds': duration,
        'requestedIntervalSeconds': interval,
        'observedWallSeconds': sum(elapsed_intervals),
        'snapshotCount': len(rss),
        'cpuSingleCorePercent': {'n': len(rates), 'p50': percentile(rates, .5),
                                 'p95': percentile(rates, .95)},
        'rssKiB': {'n': len(rss), 'max': max(rss) if rss else None},
        'notes': [
            'Complete means sampling completed, not a performance acceptance pass.',
            'CPU uses cumulative time deltas / monotonic wall deltas; 100% is one core.',
            'RSS max is a sampled maximum, not a process lifetime peak.',
            'Only this PID is measured; children and external providers are excluded.',
            'Same-executable PID reuse between snapshots cannot always be detected.',
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int, help='Explicit positive PID; no discovery')
    parser.add_argument('--duration', required=True, type=float, help='Measurement seconds, 1..120')
    parser.add_argument('--interval', type=float, default=1.0, help='Sampling wait seconds, 0.2..5 (default 1)')
    args = parser.parse_args(argv)
    try:
        validate(args.pid, args.duration, args.interval)
    except ValueError as error:
        parser.error(str(error))
    if sys.platform != 'darwin':
        print(json.dumps({'status': 'incomplete', 'reason': 'macos_required'}))
        return 2
    report = probe(args.pid, args.duration, args.interval)
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0 if report['status'] == 'complete' else 2


if __name__ == '__main__':
    sys.exit(main())
