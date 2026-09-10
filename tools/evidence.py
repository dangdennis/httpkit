#!/usr/bin/env python3
"""Source-matched local evidence; it does not certify absent production code."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
from dune_env import configuration, require_lock, command
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / '_artifacts'

def source_hash():
    digest = hashlib.sha256()
    paths = [ROOT / 'mise.toml', ROOT / 'http-kit-core.opam', ROOT / 'dune', ROOT / 'dune-project', ROOT / 'http-kit-harness.opam',
             ROOT / 'dune-workspace', ROOT / 'dune-workspace.5.2']
    for directory in ['lib', 'bench', 'test', 'fuzz', 'tools', 'toolchain', '.github', 'dune.lock', 'dune.5.2.lock']:
        paths += [p for p in (ROOT / directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
    for path in sorted(paths):
        if path.exists():
            digest.update(str(path.relative_to(ROOT)).encode() + b'\0' + path.read_bytes() + b'\0')
    return digest.hexdigest()

def record(name, extra):
    OUT.mkdir(exist_ok=True)
    data = dict(source_sha256=source_hash(), platform=platform.platform(), **extra)
    (OUT / name).write_text(json.dumps(data, indent=2) + '\n')

def check(milestone='M0'):
    expected = source_hash()
    results = {}
    for name in ['compiler-5.2.1.json', 'compiler-5.5.0.json', 'afl/evidence.json']:
        try:
            data = json.loads((OUT / name).read_text())
            ok = data.get('source_sha256') == expected and data.get('status') == 'PASS'
            if milestone == 'M2':
                if name.startswith('compiler-'):
                    ok = ok and data.get('core_consumer') is True and data.get('odoc') == '3.2.1'
                    benchmark = json.loads((OUT / ('core-bench-' + data['compiler'] + '.json')).read_text())
                    ok = ok and benchmark.get('source_sha256') == expected
                else:
                    ok = ok and int(data.get('core_execs', 0)) >= 10
            results[name] = 'PASS' if ok else 'STALE_OR_FAILED'
        except (OSError, ValueError):
            results[name] = 'MISSING'
    ok = all(v == 'PASS' for v in results.values())
    print(json.dumps({'milestone': milestone, 'status': 'PASS' if ok else 'INFRA_ERROR',
                      'source_sha256': expected, 'evidence': results}, indent=2))
    return 0 if ok else 2

def locked_packages(lock):
    return {path.name: re.search(r'\(version ([^)]+)\)', path.read_text()).group(1)
            for path in sorted(lock.glob('*.pkg'))}


def validate(version):
    dune, env, lock = configuration(version)
    require_lock(lock)
    start_hash = source_hash()
    OUT.mkdir(exist_ok=True)
    (OUT / ('compiler-' + version + '.json')).unlink(missing_ok=True)
    def run(args):
        if args[0] == dune:
            args = command(dune, env, args[1:])
        subprocess.run(args, cwd=ROOT, env=env, check=True, timeout=1800)
    run([dune, 'pkg', 'enabled'])
    run([dune, 'pkg', 'validate-lockdir', lock.name])
    run([sys.executable, str(ROOT / 'tools/test_package_management.py')])
    run([dune, 'build', '-j', '4', '@all', '@doc'])
    run([dune, 'runtest', '--force', '-j', '4'])
    run([str(ROOT / 'tools/harness'), 'run', '--tier', 'fast', '--count', '1000',
         '--report', str(OUT / ('suite-' + version + '.json')),
         '--junit', str(OUT / ('suite-' + version + '.xml'))])
    run([sys.executable, str(ROOT / 'tools/test_cli.py')])
    run([sys.executable, str(ROOT / 'tools/test_core_consumer.py')])
    benchmark = json.loads(subprocess.check_output(command(dune, env,
        ['exec', './bench/core_bench.exe']), cwd=ROOT, env=env, text=True))
    if len(benchmark['results']) != 15 or any(r['ns_per_op'] <= 0 or
            r['allocated_bytes_per_op'] < 0 for r in benchmark['results']):
        raise RuntimeError('incomplete or invalid core benchmark')
    record('core-bench-' + version + '.json', benchmark)
    doctor = json.loads(subprocess.check_output([str(ROOT / 'tools/harness'), 'doctor'],
                                               cwd=ROOT, env=env, text=True))
    actual = doctor['ocaml']
    if actual != version or source_hash() != start_hash:
        raise RuntimeError('compiler mismatch or sources changed during validation')
    record('compiler-' + version + '.json', {'status': 'PASS', 'compiler': actual,
           'dependency_manager': 'dune', 'lock_directory': lock.name,
           'packages': locked_packages(lock), 'core_consumer': True, 'odoc': '3.2.1'})

if __name__ == '__main__':
    if sys.argv[1:] == ['packages']:
        _, _, lock = configuration()
        require_lock(lock)
        print(json.dumps({'lock_directory': lock.name, 'packages': locked_packages(lock)}, sort_keys=True))
        sys.exit(0)
    if sys.argv[1:] == ['fingerprint']:
        print(source_hash())
        sys.exit(0)
    if sys.argv[1:] == ['check']:
        sys.exit(check())
    if sys.argv[1:] == ['check', 'M2']:
        sys.exit(check('M2'))
    if len(sys.argv) == 3 and sys.argv[1] == 'validate' and sys.argv[2] in ['5.2.1', '5.5.0']:
        validate(sys.argv[2])
    else:
        sys.exit('usage: evidence.py check | validate 5.2.1|5.5.0')
