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
    paths += list(ROOT.glob('*.opam'))
    for directory in ['examples', 'lib', 'bench', 'test', 'fuzz', 'tools', 'toolchain', '.github', 'dune.lock', 'dune.5.2.lock']:
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
    rank = int(milestone[1:])
    names = ['compiler-5.2.1.json', 'compiler-5.5.0.json', 'afl/evidence.json']
    if rank >= 6:
        names += ['interop-5.2.1.json', 'interop-5.5.0.json', 'performance-5.5.0.json']
    results = {}
    for name in names:
        try:
            data = json.loads((OUT / name).read_text())
            ok = data.get('source_sha256') == expected and data.get('status') == 'PASS'
            if name.startswith('compiler-'):
                if rank >= 2:
                    ok = ok and data.get('core_consumer') is True and data.get('odoc') == '3.2.1'
                    benchmark = json.loads((OUT / ('core-bench-' + data['compiler'] + '.json')).read_text())
                    ok = ok and benchmark.get('source_sha256') == expected
                if rank >= 3: ok = ok and data.get('http1_consumer') is True
                if rank >= 4: ok = ok and data.get('engine_consumer') is True
                if rank >= 5: ok = ok and data.get('adapter_consumer') is True
            elif name == 'afl/evidence.json':
                for minimum, field in [(2, 'core_execs'), (3, 'http1_execs'), (4, 'engine_execs')]:
                    if rank >= minimum: ok = ok and int(data.get(field, 0)) >= 10
            elif name.startswith('interop-'):
                ok = ok and len(data.get('results', [])) == 6
            elif name.startswith('performance-'):
                ok = ok and data.get('hard_queue_bound') == 32768 and len(data.get('mixed_loads', [])) == 2
            results[name] = 'PASS' if ok else 'STALE_OR_FAILED'
        except (OSError, ValueError, KeyError, TypeError):
            results[name] = 'MISSING_OR_INVALID'
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
    run([sys.executable, str(ROOT / 'tools/test_protocol_consumer.py')])
    run([sys.executable, str(ROOT / 'tools/test_adapter_consumer.py')])
    benchmark = json.loads(subprocess.check_output(command(dune, env,
        ['exec', './bench/core_bench.exe']), cwd=ROOT, env=env, text=True))
    if len(benchmark['results']) != 15 or any(r['ns_per_op'] <= 0 or
            r['allocated_bytes_per_op'] < 0 for r in benchmark['results']):
        raise RuntimeError('incomplete or invalid core benchmark')
    record('core-bench-' + version + '.json', benchmark)
    http1_benchmark = json.loads(subprocess.check_output(command(dune, env, ['exec', './bench/http1_bench.exe']), cwd=ROOT, env=env, text=True))
    if len(http1_benchmark['results']) != 6:
        raise RuntimeError('incomplete HTTP/1 benchmark')
    record('http1-bench-' + version + '.json', http1_benchmark)
    doctor = json.loads(subprocess.check_output([str(ROOT / 'tools/harness'), 'doctor'],
                                               cwd=ROOT, env=env, text=True))
    actual = doctor['ocaml']
    if actual != version or source_hash() != start_hash:
        raise RuntimeError('compiler mismatch or sources changed during validation')
    record('compiler-' + version + '.json', {'status': 'PASS', 'compiler': actual,
           'dependency_manager': 'dune', 'lock_directory': lock.name,
           'packages': locked_packages(lock), 'core_consumer': True, 'http1_consumer': True, 'engine_consumer': True, 'adapter_consumer': True, 'odoc': '3.2.1'})

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
    if len(sys.argv)==3 and sys.argv[1]=='check' and sys.argv[2] in ['M2','M3','M4','M5','M6']:
        sys.exit(check(sys.argv[2]))
    if len(sys.argv) == 3 and sys.argv[1] == 'validate' and sys.argv[2] in ['5.2.1', '5.5.0']:
        validate(sys.argv[2])
    else:
        sys.exit('usage: evidence.py check | validate 5.2.1|5.5.0')
