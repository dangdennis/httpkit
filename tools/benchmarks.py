#!/usr/bin/env python3
"""Repeat native OCaml workloads; retain samples and compare compatible reports."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

from dune_env import ROOT, command, configuration, require_lock
from evidence import source_hash

FAMILIES = ('all', 'core', 'router', 'http1', 'middleware', 'engine')
SCHEMA = 1


def need(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, positive=False):
    return (type(value) in (int, float) and math.isfinite(value)
            and (value > 0 if positive else value >= 0))


def inventory(rows):
    need(isinstance(rows, list) and rows, 'empty workload catalog')
    catalog = {}
    for row in rows:
        case = row['id']
        need(isinstance(case, str) and case not in catalog, 'duplicate or invalid case id')
        need(row['family'] in FAMILIES[1:] and case.startswith(row['family'] + '/'), 'invalid family')
        need(type(row['iterations']) is int and row['iterations'] > 0, 'invalid iterations')
        need(type(row['bytes_per_op']) is int and row['bytes_per_op'] >= 0, 'invalid byte count')
        catalog[case] = {key: row[key] for key in ('id', 'family', 'iterations', 'bytes_per_op')}
    return catalog


def aggregate(samples, catalog, compiler, quick):
    expected = inventory(catalog)
    need(len(samples) >= 2, 'at least two independent samples required')
    for sample in samples:
        need(sample['schema'] == SCHEMA and sample['compiler'] == compiler
             and sample['quick'] is quick, 'incompatible sample metadata')
        need(inventory(sample['results']) == expected, 'sample workload catalog differs')
        for row in sample['results']:
            need(number(row['elapsed_ns'], positive=True) and number(row['ns_per_op'], positive=True)
                 and number(row['allocated_bytes_per_op']), 'invalid measurement')
            need(math.isclose(row['ns_per_op'] * row['iterations'], row['elapsed_ns'], rel_tol=1e-9),
                 'inconsistent elapsed time')
            need(row['warmups'] == min(3, row['iterations']), 'invalid warmup count')
            for key in ('minor_collections', 'major_collections'):
                need(type(row[key]) is int and row[key] >= 0, 'invalid GC count')
    indexed = [{r['id']: r for r in s['results']} for s in samples]
    results = []
    for case, entry in sorted(expected.items()):
        rows = [s[case] for s in indexed]
        times = [r['ns_per_op'] for r in rows]
        median = statistics.median(times)
        results.append(dict(entry, median_ns_per_op=median, min_ns_per_op=min(times), max_ns_per_op=max(times),
                            coefficient_of_variation=statistics.stdev(times) / statistics.mean(times),
                            median_allocated_bytes_per_op=statistics.median(r['allocated_bytes_per_op'] for r in rows),
                            operations_per_second=1e9 / median,
                            payload_mib_per_second=(entry['bytes_per_op'] * 1e9 / median / 1048576
                                                    if entry['bytes_per_op'] else None)))
    return results


def compare(current, baseline):
    # Production source hashes may differ; workload, toolchain and host may not.
    # This compatibility check cannot establish thermal/load isolation.
    for key in ('schema', 'compiler', 'profile', 'workload_sha256', 'host_fingerprint', 'config'):
        need(current[key] == baseline[key], f'incompatible baseline: {key}')
    for report in (current, baseline):
        rebuilt = aggregate(report['samples'], report['catalog'], report['compiler'], report['config']['quick'])
        need(report['results'] == rebuilt, 'report summary does not match retained samples')
        need(len(report['samples']) == report['config']['samples'], 'report sample count differs')
        need([s['seed'] for s in report['samples']] == report['config']['seeds'], 'report seed order differs')
    need(inventory(current['catalog']) == inventory(baseline['catalog']), 'incompatible baseline: catalog')
    old = {r['id']: r for r in baseline['results']}
    deltas = []
    for row in current['results']:
        previous = old[row['id']]
        before = previous['median_allocated_bytes_per_op']
        delta = row['median_allocated_bytes_per_op'] - before
        deltas.append({'id': row['id'], 'time_change_percent':
                       100 * (row['median_ns_per_op'] / previous['median_ns_per_op'] - 1),
                       'allocation_change_bytes_per_op': delta,
                       'allocation_change_percent': 100 * delta / before if before else None})
    return deltas


def workload_hash():
    digest = hashlib.sha256()
    paths = list((ROOT / 'bench').glob('suite_*.ml'))
    paths += [ROOT / p for p in ('bench/dune', 'tools/benchmarks.py', 'tools/dune_env.py',
                                 'dune', 'dune-project', 'dune-workspace', 'toolchain/manifest.json')]
    paths += [p for p in (ROOT / 'dune.lock').rglob('*') if p.is_file()]
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes() + b'\0')
    return digest.hexdigest()


def markdown(report):
    lines = ['# HTTP toolkit benchmarks', '',
             f"{len(report['results'])} cases; {len(report['samples'])} fresh process samples; OCaml {report['compiler']}; release profile.",
             '', 'Timing verdict: **ADVISORY**. Timed operations include result checks. Throughput uses the byte count documented for each family.',
             '', '| Case | Median ns/op | Range ns/op | CV | Alloc B/op | MiB/s |',
             '| --- | ---: | ---: | ---: | ---: | ---: |']
    for r in report['results']:
        throughput = '-' if r['payload_mib_per_second'] is None else f"{r['payload_mib_per_second']:.2f}"
        lines.append(f"| {r['id']} | {r['median_ns_per_op']:.1f} | {r['min_ns_per_op']:.1f}–{r['max_ns_per_op']:.1f} | "
                     f"{r['coefficient_of_variation']:.1%} | {r['median_allocated_bytes_per_op']:.1f} | {throughput} |")
    if 'comparison' in report:
        lines += ['', 'Positive changes mean slower execution or more allocation. No regression gate is applied.', '',
                  '| Case | Time change | Allocation change B/op |', '| --- | ---: | ---: |']
        for r in report['comparison']:
            lines.append(f"| {r['id']} | {r['time_change_percent']:+.1f}% | {r['allocation_change_bytes_per_op']:+.1f} |")
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--family', choices=FAMILIES, default='all')
    parser.add_argument('--samples', type=int, default=5)
    parser.add_argument('--quick', action='store_true', help='Tenfold fewer iterations; smoke evidence only')
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--baseline', type=Path, help='Compatible retained report.json to compare')
    args = parser.parse_args()
    if not 2 <= args.samples <= 50:
        parser.error('--samples must be between 2 and 50')
    if not 0 <= args.seed <= 2147483647 - args.samples:
        parser.error('--seed must fit a positive signed 32-bit seed sequence')
    dune, env, lock = configuration()
    require_lock(lock)
    # Clear instrumentation and runtime tuning inherited from fuzz/coverage or a
    # developer's shell. Never reuse their build directory for timing samples.
    cleared = []
    for key in list(env):
        if key.startswith(('BISECT_', 'AFL_')) or key in (
                'OCAMLPARAM', 'OCAMLRUNPARAM', 'CAMLRUNPARAM', 'DUNE_INSTRUMENT_WITH'):
            cleared.append(key)
            env.pop(key)
    compiler = env['HARNESS_COMPILER']
    build_dir = '_build-bench-' + compiler
    digest, workload = source_hash(), workload_hash()
    subprocess.run(command(dune, env, ['build', '--profile=release', '--build-dir=' + build_dir,
                                       'bench/suite_bench.exe']), cwd=ROOT, env=env, check=True, timeout=1800)
    binary = ROOT / build_dir / 'default/bench/suite_bench.exe'
    flags = ['--family', args.family] + (['--quick'] if args.quick else [])
    catalog_sample = json.loads(subprocess.check_output([str(binary), *flags, '--list'], env=env, text=True, timeout=60))
    need(catalog_sample['compiler'] == compiler, 'wrong benchmark compiler')
    catalog = catalog_sample['results']
    inventory(catalog)
    parent = ROOT / '_artifacts/benchmarks'
    parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent))
    samples = []
    seeds = list(range(args.seed, args.seed + args.samples))
    for index, seed in enumerate(seeds):
        raw = subprocess.check_output([str(binary), *flags, '--seed', str(seed)], env=env, text=True, timeout=600)
        (directory / f'sample-{index + 1}.json').write_text(raw)
        samples.append(json.loads(raw))
        print(f'Sample {index + 1}/{args.samples}: {len(samples[-1]["results"])} cases', flush=True)
    need(source_hash() == digest, 'sources changed during benchmark run')
    host = dict(system=platform.system(), release=platform.release(), machine=platform.machine(),
                processor=platform.processor(), cpu_count=os.cpu_count())
    fingerprint = hashlib.sha256((platform.node() + json.dumps(host, sort_keys=True)).encode()).hexdigest()
    report = dict(schema=SCHEMA, status='PASS', timing_verdict='ADVISORY', compiler=compiler, profile='release',
                  source_sha256=digest, workload_sha256=workload, host=host, host_fingerprint=fingerprint,
                  cleared_environment=sorted(cleared), catalog=catalog, samples=samples,
                  config=dict(family=args.family, quick=args.quick, samples=args.samples, seeds=seeds),
                  results=aggregate(samples, catalog, compiler, args.quick),
                  limitations=['Timed operations include correctness checks and loop overhead.',
                               'Sample means are not request latency percentiles.',
                               'Host identity does not establish reserved hardware, stable power or load.',
                               'These measurements do not approve M7 performance or security gates.'])
    if args.baseline:
        report['comparison'] = compare(report, json.loads(args.baseline.read_text()))
        report['baseline'] = str(args.baseline.resolve())
    (directory / 'report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    (directory / 'report.md').write_text(markdown(report))
    noisy = sum(r['coefficient_of_variation'] > .1 for r in report['results'])
    print(f'PASS: {len(report["results"])} cases; {noisy} with CV > 10%; timing ADVISORY\n{directory / "report.md"}')


if __name__ == '__main__':
    main()
