#!/usr/bin/env python3
"""Offline, stdlib-only release evidence evaluator. Never records or contacts services."""
import argparse
import json
import math
import re
import sys
import unicodedata
from pathlib import Path

CATEGORIES = ('normal', 'quiet', 'fast', 'single_word', 'pause',
              'quick_release', 'silence', 'noise')
METRICS = ('hudMs', 'firstInterimMs', 'releaseToFinalMs')


def normalize(text):
    text = unicodedata.normalize('NFC', text).translate(str.maketrans({'I': 'ı', 'İ': 'i'})).casefold()
    return ''.join(' ' if unicodedata.category(c).startswith('P') else c for c in text).split()


def word_errors(reference, hypothesis):
    ref, hyp = normalize(reference), normalize(hypothesis)
    previous = list(range(len(hyp) + 1))
    for i, a in enumerate(ref, 1):
        current = [i]
        for j, b in enumerate(hyp, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (a != b)))
        previous = current
    return previous[-1], len(ref), len(hyp) if not ref else 0


def numeric(value):
    return (type(value) in (int, float) and value >= 0
            and (type(value) is int or math.isfinite(value)))


def percentile(values, fraction):
    """Linear interpolation at (n-1)*fraction; no rounding before decisions."""
    if not values:
        return None
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lo, hi = math.floor(position), math.ceil(position)
    return values[lo] + (values[hi] - values[lo]) * (position - lo)


def indexed(rows, label):
    if not isinstance(rows, list):
        raise ValueError(label + ': expected array')
    result = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('id'), str) or not row['id']:
            raise ValueError(label + ': each row needs a nonempty string id')
        if row['id'] in result:
            raise ValueError(label + ': duplicate id')
        result[row['id']] = row
    return result


def import_log(path, cases):
    """Use explicit physical line numbers; never return raw lines or transcripts."""
    selected = {}
    for case in cases.values():
        line = case.get('record_latency_line')
        if line is not None:
            if type(line) is not int or line < 1 or line in selected:
                raise ValueError('record_latency_line must be unique positive integers')
            selected[line] = case['id']
    result = []
    with Path(path).open(encoding='utf-8') as source:
        for number, line in enumerate(source, 1):
            if number not in selected:
                continue
            match = re.search(r'\[RecordLatency\] provider=\S+ model=\S+ (.*?) end=\S+\s*$', line)
            metrics = {}
            if match:
                for token, target in [('firstInterim', 'firstInterimMs'),
                                      ('preparingPresented', 'preparingPresentedMs'),
                                      ('hudRunLoopYield', 'hudRunLoopYieldMs')]:
                    values = re.findall(r'(?:^|\s)' + token + r'=(\d+)ms(?=\s|$)', match[1])
                    if len(values) == 1:
                        metrics[target] = int(values[0])
            result.append({'id': selected[number], **metrics})
    return result


def evaluate(manifest, speech_rows, latency_rows, thresholds, minimum=1, imported=None,
             real_measurements=False):
    if type(minimum) is not int or minimum < 1:
        raise ValueError('minimum must be a positive integer')
    if not isinstance(manifest, dict):
        raise ValueError('manifest must be an object')
    devices = manifest.get('devices')
    if (not isinstance(devices, list) or not devices
            or any(not isinstance(d, str) or not d.strip() for d in devices)
            or len(set(devices)) != len(devices)):
        raise ValueError('manifest devices must be unique nonempty strings')
    cases = indexed(manifest.get('cases'), 'manifest cases')
    for case in cases.values():
        if case.get('device') not in devices or case.get('category') not in CATEGORIES:
            raise ValueError('manifest case has unknown device/category')
    speech = indexed(speech_rows, 'speech')
    latency = indexed(latency_rows, 'latency')
    logs = indexed(imported or [], 'log import')
    if (set(speech) | set(latency) | set(logs)) - set(cases):
        raise ValueError('measurement id absent from manifest')
    for key, value in thresholds.items():
        if key not in (*METRICS, 'werPercent') or not numeric(value):
            raise ValueError('thresholds must be known, finite nonnegative numbers')
    notes, failures = [], []
    if not real_measurements:
        notes.append('Real user-provided measurements not attested; synthetic/unverified evidence cannot pass.')
    for key in (*METRICS, 'werPercent'):
        if key not in thresholds:
            notes.append('Missing acceptance threshold: ' + key)
    groups = []
    for device in devices:
        for category in CATEGORIES:
            ids = sorted(k for k, c in cases.items() if c['device'] == device and c['category'] == category)
            group = {'device': device, 'category': category, 'planned': len(ids)}
            label = device + '/' + category
            errors = words = hallucinations = completed = 0
            samples = {key: [] for key in METRICS}
            for case_id in ids:
                row = speech.get(case_id, {})
                if not all(isinstance(row.get(k), str) for k in ('reference', 'hypothesis')):
                    notes.append(label + ': missing/invalid speech pair for ' + case_id)
                elif bool(normalize(row['reference'])) == (category in ('silence', 'noise')):
                    notes.append(label + ': reference incompatible with category for ' + case_id)
                else:
                    e, w, h = word_errors(row['reference'], row['hypothesis'])
                    errors += e
                    words += w
                    hallucinations += h
                    completed += 1
                for key in METRICS:
                    if key == 'firstInterimMs' and category in ('silence', 'noise'):
                        continue
                    explicit = latency.get(case_id, {})
                    value = explicit.get(key) if key in explicit else logs.get(case_id, {}).get(key)
                    if numeric(value):
                        samples[key].append(value)
                    else:
                        notes.append(label + ': missing/invalid ' + key + ' for ' + case_id)
            if len(ids) < minimum or completed < minimum:
                notes.append(label + ': insufficient coverage (minimum ' + str(minimum) + ')')
            wer = errors / words * 100 if words else None
            group.update(completed=completed, wordErrors=errors, referenceWords=words,
                         werPercent=wer, hallucinatedWords=hallucinations)
            if hallucinations:
                failures.append(label + ': empty-reference hallucination')
            if wer is not None and 'werPercent' in thresholds and wer > thresholds['werPercent']:
                failures.append(label + ': WER exceeds threshold')
            group['latency'] = {}
            for key, values in samples.items():
                applicable = not (key == 'firstInterimMs' and category in ('silence', 'noise'))
                stats = {'n': len(values), 'p50': percentile(values, .50),
                         'p95': percentile(values, .95), 'applicable': applicable}
                group['latency'][key] = stats
                if applicable and len(values) < minimum:
                    notes.append(label + ': insufficient ' + key + ' samples')
                if values and key in thresholds and stats['p95'] > thresholds[key]:
                    failures.append(label + ': ' + key + ' p95 exceeds threshold')
            groups.append(group)
    return {'status': 'not-ready' if notes else ('fail' if failures else 'pass'),
            'notes': notes, 'failures': failures, 'groups': groups,
            'thresholds': thresholds, 'minimumPerDeviceCategory': minimum,
            'realMeasurementsAttested': real_measurements,
            'logImportNote': 'Read-only. HUD milestones are proxies, not hudMs; releaseToFinalMs is not logged.'}


def read_json(path):
    with Path(path).open(encoding='utf-8') as source:
        return json.load(source)


def read_jsonl(path):
    rows = []
    with Path(path).open(encoding='utf-8') as source:
        for number, line in enumerate(source, 1):
            if line.strip():
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    raise ValueError('Invalid speech JSONL at line ' + str(number)) from None
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--speech', required=True, help='JSONL reference/hypothesis pairs')
    parser.add_argument('--latency', help='JSON array of per-case millisecond samples')
    parser.add_argument('--record-latency-log', help='Explicit local file; read-only selected lines')
    parser.add_argument('--thresholds', help='JSON object: werPercent and metric p95 limits')
    parser.add_argument('--min-per-category', type=int, default=1)
    parser.add_argument('--attest-real-measurements', action='store_true')
    args = parser.parse_args(argv)
    try:
        manifest = read_json(args.manifest)
        imported = import_log(args.record_latency_log, indexed(manifest.get('cases'), 'manifest')) if args.record_latency_log else []
        report = evaluate(manifest, read_jsonl(args.speech),
                          read_json(args.latency) if args.latency else [],
                          read_json(args.thresholds) if args.thresholds else {},
                          args.min_per_category, imported, args.attest_real_measurements)
        print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
        return {'pass': 0, 'fail': 1, 'not-ready': 2}[report['status']]
    except (OSError, ValueError, TypeError, AttributeError, OverflowError):
        # Parser exceptions and raw lines may contain private speech. Do not echo them.
        print(json.dumps({'status': 'not-ready', 'notes': ['Invalid/unreadable input; check documented schemas.']}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
