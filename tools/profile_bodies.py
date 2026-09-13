#!/usr/bin/env python3
"""Single-fixture body diagnostics; OS sampling is separate from timed evidence."""
import argparse
from datetime import datetime, timezone
import json
import platform
import subprocess
import tempfile

from dune_env import ROOT, command, configuration, require_lock
from evidence import source_hash


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iterations', type=int, default=50)
    parser.add_argument('--stack', action='store_true', help='Separate macOS sample runs; never rank their timings')
    args = parser.parse_args()
    if not 1 <= args.iterations <= 10000:
        parser.error('--iterations must be between 1 and 10000')
    if platform.system() not in ('Darwin', 'Linux'):
        parser.error('OS resource capture supports macOS and Linux')
    if args.stack and platform.system() != 'Darwin':
        parser.error('--stack uses macOS sample; use perf separately on Linux')
    dune, env, lock = configuration()
    require_lock(lock)
    for key in list(env):
        if key.startswith(('BISECT_', 'AFL_')) or key in ('OCAMLPARAM', 'OCAMLRUNPARAM', 'CAMLRUNPARAM', 'DUNE_INSTRUMENT_WITH'):
            env.pop(key)
    digest = source_hash()
    build = '_build-bench-' + env['HARNESS_COMPILER']
    subprocess.run(command(dune, env, ['build', '--profile=release', '--build-dir='+build,
                                       'bench/suite_bench.exe']), cwd=ROOT, env=env, check=True, timeout=1800)
    binary = ROOT / build / 'default/bench/suite_bench.exe'
    parent = ROOT / '_artifacts/body-profiles'
    parent.mkdir(parents=True, exist_ok=True)
    directory = tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=parent)
    from pathlib import Path
    directory = Path(directory)
    rows = []
    for implementation in ('httpkit', 'httpaf', 'httpun'):
        for mode in ('owned-scan', 'borrowed-scan', 'collect'):
            name = implementation+'-'+mode
            flags = [str(binary), '--body-profile', implementation+'/'+mode,
                     '--profile-iterations', str(args.iterations)]
            result = subprocess.run(['/usr/bin/time', '-l' if platform.system() == 'Darwin' else '-v', *flags],
                                    cwd=ROOT, env=env, capture_output=True, text=True, check=True, timeout=300)
            (directory/(name+'.json')).write_text(result.stdout)
            (directory/(name+'-resources.txt')).write_text(result.stderr)
            rows.append(json.loads(result.stdout))
            print(name+' passed', flush=True)
        if args.stack:
            # Profiling overhead changes timing: this is a second process and
            # its measurements are kept apart from the uninstrumented rows.
            with (directory/(implementation+'-sampled.json')).open('w') as output:
                process = subprocess.Popen([str(binary), '--body-profile', implementation+'/owned-scan',
                                            '--profile-iterations', '1000'], cwd=ROOT, env=env, stdout=output)
                try:
                    sample = subprocess.run(['/usr/bin/sample', str(process.pid), '1', '1', '-file',
                                             str(directory/(implementation+'-stacks.txt'))],
                                            capture_output=True, text=True, timeout=30)
                    (directory/(implementation+'-sample-status.txt')).write_text(
                        f'exit={sample.returncode}\n'+sample.stdout+sample.stderr)
                    if sample.returncode:
                        raise RuntimeError('stack capture failed; see retained sample status')
                    if process.wait(timeout=300):
                        raise RuntimeError('sampled body process failed')
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
    if source_hash() != digest:
        raise RuntimeError('sources changed during diagnostics')
    report = dict(source_sha256=digest, compiler=env['HARNESS_COMPILER'], system=platform.system(),
                  results=rows, limitations=[
                      'Single-fixture, single-process diagnostics are not repeated timing comparisons.',
                      'GC allocation, post-collection live words, explicit fixture Bigarray bytes, and OS peak RSS are different quantities.',
                      'Peak RSS includes runtime, fixture, allocator retention and profiler startup; not per-connection retained memory.',
                      'httpkit public Data remains owned even in the borrowed-scan consumer lane.',
                      'OS stack capture uses separate instrumented processes.'])
    (directory/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(directory/'report.json')


if __name__ == '__main__':
    main()
