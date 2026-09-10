#!/usr/bin/env python3
"""Prove coverage changes, find/replay a planted defect, then fuzz the harness."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
from evidence import ROOT, source_hash
from dune_env import configuration, require_lock, command

manifest = json.loads((ROOT / 'toolchain/manifest.json').read_text())
dune, env, lock = configuration()
require_lock(lock)
version = env['HARNESS_COMPILER']
env.update(AFL_SKIP_CPUFREQ='1', AFL_NO_AFFINITY='1', AFL_MAP_SIZE='65536', AFL_CRASH_EXITCODE='2',
           AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES='1', AFL_NO_UI='1')
afl = ROOT / '.toolchain/afl'
out = ROOT / '_artifacts/afl'
out.mkdir(parents=True, exist_ok=True)
evidence = out / 'evidence.json'
evidence.unlink(missing_ok=True)
digest = source_hash()

def run(args, *, extra=None, logfile=None, expected=0):
    if args[0] == dune:
        args = command(dune, env, args[1:])
    target_env = dict(env, **(extra or {}))
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=target_env,
                       capture_output=True, timeout=1800)
    if logfile:
        Path(logfile).write_bytes(p.stdout + p.stderr)
    if p.returncode != expected:
        raise RuntimeError(f'{args}: exit {p.returncode}\n' + (p.stdout + p.stderr).decode(errors='replace')[-4000:])
    return p

repository, tag, revision = (ROOT / manifest['afl_pin']).read_text().split()
if not all((afl / name).is_file() for name in ['afl-fuzz', 'afl-showmap']):
    sys.exit('AFL++ is missing; run mise run setup:afl')
actual = run(['git', '-C', afl, 'rev-parse', 'HEAD']).stdout.decode().strip()
if actual != revision:
    sys.exit('AFL revision mismatch; run mise run setup:afl with the pinned checkout')
run(['git', '-C', afl, 'diff', '--quiet', 'HEAD', '--'])
prefix = [dune]
build = '_build-fuzz-pkg-' + version
run(prefix + ['pkg', 'validate-lockdir', lock.name])
run(prefix + ['build', '--profile', 'fuzz', '--build-dir', build, '-j', '4',
              'fuzz/instrumentation.exe', 'fuzz/scenario_fuzz.exe', 'fuzz/core_fuzz.exe'])
run(prefix + ['build', 'fuzz/instrumentation.exe', 'fuzz/scenario_fuzz.exe', 'fuzz/core_fuzz.exe'])
binary = ROOT / build / 'default/fuzz/instrumentation.exe'
plain = ROOT / ('_build-pkg-' + version) / 'default/fuzz/instrumentation.exe'
target = ROOT / build / 'default/fuzz/scenario_fuzz.exe'
plain_crowbar = ROOT / ('_build-pkg-' + version) / 'default/fuzz/scenario_fuzz.exe'
with tempfile.TemporaryDirectory(prefix='run-', dir=out) as temp:
    temp = Path(temp)
    seeds = temp / 'seeds'
    seeds.mkdir()
    (seeds / 'a').write_bytes(b'A')
    (temp / 'b').write_bytes(b'B')
    maps = []
    for name, path in [('a', seeds / 'a'), ('b', temp / 'b')]:
        mapfile = out / (name + '.map')
        run([afl / 'afl-showmap', '-q', '-m', '512', '-o', mapfile, '--', binary, path],
            logfile=out / (name + '-map.log'))
        maps.append(mapfile.read_bytes())
    if not maps[0] or not maps[1] or maps[0] == maps[1]:
        raise RuntimeError('instrumentation did not expose different coverage')
    dictionary = temp / 'dictionary'
    dictionary.write_text('fault="!"\n')
    run([afl / 'afl-fuzz', '-V', '8', '-m', '512', '-t', '1000', '-i', seeds,
         '-o', temp / 'planted', '-x', dictionary, '--', binary, '@@'],
        extra={'HTTP_KIT_PLANTED_FAULT': '1', 'AFL_CRASH_EXITCODE': '2'}, logfile=out / 'planted.log')
    crashes = [p for p in (temp / 'planted').rglob('id:*') if p.parent.name == 'crashes']
    if not crashes:
        raise RuntimeError('fuzzer did not find the planted fault within the smoke budget')
    reproducer = out / 'planted.input'
    reproducer.write_bytes(crashes[0].read_bytes())
    run([plain, reproducer], extra={'HTTP_KIT_PLANTED_FAULT': '1'},
        logfile=out / 'replay.log', expected=2)
    # Crowbar's own persistent runner must work, rather than assuming it does.
    # Crowbar consumes a test selector then a NUL-terminated byte string.
    # An unterminated seed may be discarded before reaching first-party code.
    (seeds / 'a').write_bytes(b'\x00abc\x00')
    (seeds / 'b').write_bytes(b'\x01{}\x00')
    run([afl / 'afl-fuzz', '-V', '8', '-m', '512', '-t', '1000', '-i', seeds,
         '-o', temp / 'crowbar-planted', '-x', dictionary, '--', target, '@@'],
        extra={'HTTP_KIT_CROWBAR_PLANTED_FAULT': '1'}, logfile=out / 'crowbar-planted.log')
    crowbar_crashes = [p for p in (temp / 'crowbar-planted').rglob('id:*') if p.parent.name == 'crashes']
    if not crowbar_crashes:
        raise RuntimeError('Crowbar assertion failures were not discovered as AFL crashes')
    crowbar_repro = out / 'crowbar-planted.input'
    crowbar_repro.write_bytes(crowbar_crashes[0].read_bytes())
    run([plain_crowbar, crowbar_repro], extra={'HTTP_KIT_CROWBAR_PLANTED_FAULT': '1'},
        logfile=out / 'crowbar-replay.log', expected=2)
    run([afl / 'afl-fuzz', '-V', '5', '-m', '512', '-t', '1000', '-i', seeds,
         '-o', temp / 'harness', '--', target, '@@'], logfile=out / 'harness.log')
    harness_crashes = [p for p in (temp / 'harness').rglob('id:*') if p.parent.name in ('crashes', 'hangs')]
    if harness_crashes:
        for i, path in enumerate(harness_crashes):
            (out / f'harness-finding-{i}.input').write_bytes(path.read_bytes())
        raise RuntimeError('harness fuzzing found crashes/hangs; reproducers preserved')
    stats_files = list((temp / 'harness').rglob('fuzzer_stats'))
    if len(stats_files) != 1:
        raise RuntimeError('missing fuzzer statistics')
    stats_text = stats_files[0].read_text()
    stats = dict(line.split(':', 1) for line in stats_text.splitlines() if ':' in line)
    stats = {k.strip(): v.strip() for k, v in stats.items()}
    if int(stats.get('execs_done', '0')) < 10:
        raise RuntimeError('insufficient fuzz execution')
    (out / 'harness-stats.txt').write_text(stats_text)
    core_target = ROOT / build / 'default/fuzz/core_fuzz.exe'
    run([afl / 'afl-fuzz', '-V', '5', '-m', '512', '-t', '1000', '-i', seeds,
         '-o', temp / 'core', '--', core_target, '@@'], logfile=out / 'core.log')
    findings = [p for p in (temp / 'core').rglob('id:*') if p.parent.name in ('crashes', 'hangs')]
    if findings:
        for i, path in enumerate(findings):
            (out / f'core-finding-{i}.input').write_bytes(path.read_bytes())
        raise RuntimeError('core fuzzing found crashes/hangs; reproducers preserved')
    core_stats_files = list((temp / 'core').rglob('fuzzer_stats'))
    if len(core_stats_files) != 1:
        raise RuntimeError('missing core fuzzer statistics')
    core_stats_text = core_stats_files[0].read_text()
    core_stats = {k.strip(): v.strip() for k, v in
                  (line.split(':', 1) for line in core_stats_text.splitlines() if ':' in line)}
    if int(core_stats.get('execs_done', '0')) < 10:
        raise RuntimeError('insufficient core fuzz execution')
    (out / 'core-stats.txt').write_text(core_stats_text)
if source_hash() != digest:
    raise RuntimeError('sources changed during fuzz validation')
data = {'status': 'PASS', 'source_sha256': digest, 'afl_revision': actual,
        'compiler': version, 'lock_directory': lock.name, 'coverage_maps_differ': True, 'planted_fault_found': True,
        'uninstrumented_replay_failed_as_expected': True, 'crowbar_execs': stats['execs_done'],
        'crowbar_assertion_discovered_and_replayed': True,
        'core_execs': core_stats['execs_done'],
        'scope': 'M0 instrumentation, M1 synthetic harness, M2 core values; no wire protocol fuzzing'}
evidence.write_text(json.dumps(data, indent=2) + '\n')
print(json.dumps(data, indent=2))
