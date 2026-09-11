#!/usr/bin/env python3
"""Install the pure router without codecs/adapters and reject forged patterns."""
from checks import require
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from dune_env import ROOT, configuration, command

dune, env, _ = configuration()
compiler = Path(subprocess.check_output(command(dune, env,
    ['exec', '--', 'sh', '-c', 'command -v ocamlc']), cwd=ROOT, env=env,
    text=True).strip()).resolve()
clean = {k: v for k, v in env.items() if not k.startswith(('OCAML', 'CAML', 'DUNE'))}
clean['PATH'] = str(compiler.parent) + os.pathsep + clean['PATH']
with tempfile.TemporaryDirectory(prefix='http-kit-router-') as directory:
    root = Path(directory); source = root / 'source'; source.mkdir()
    for name in ['core', 'router']:
        shutil.copytree(ROOT / 'lib' / name, source / name)
        shutil.copy2(ROOT / f'http-kit-{name}.opam', source)
    (source / 'dune-project').write_text('(lang dune 3.24)\n(name installed-router)\n')
    (source / 'dune-workspace').write_text('(lang dune 3.24)\n(pkg disabled)\n')
    prefix = root / 'installed'
    for args in [['build', '@install'], ['install', '--prefix', str(prefix), 'http-kit-core', 'http-kit-router']]:
        subprocess.run([dune, *args], cwd=source, env=clean, check=True, capture_output=True, timeout=120)
    require(sorted(p.name for p in (prefix / 'lib').iterdir()) == ['http-kit-core', 'http-kit-router'], "test_router_consumer.py: sorted(p.name for p in (prefix / 'lib').iterdir()) == ['http-kit-core', 'http-kit-router']")
    includes = [str(prefix / 'lib' / name) for name in ['http-kit-core', 'http-kit-router']]
    for fixture in (ROOT / 'test/api/router').glob('*.ml'):
        shutil.copy2(fixture, root / fixture.name)
    for mode, tool, extension in [('byte', compiler, 'cma'), ('native', compiler.with_name('ocamlopt'), 'cmxa')]:
        args = [str(tool), *[x for path in includes for x in ['-I', path]],
                str(Path(includes[0]) / ('http_kit_core.' + extension)),
                str(Path(includes[1]) / ('http_kit_router.' + extension)), 'consumer.ml', '-o', 'consumer-' + mode]
        subprocess.run(args, cwd=root, env=clean, check=True, capture_output=True, timeout=30)
        exe = str(root / ('consumer-' + mode))
        run = [str(compiler.with_name('ocamlrun')), exe] if mode == 'byte' else [exe]
        require(subprocess.check_output(run, cwd=root, env=clean, timeout=30) == b'PASS: installed pure router\n', "test_router_consumer.py: subprocess.check_output(run, cwd=root, env=clean, timeout=30) == b'PASS: installed pure router\\n'")
    result = subprocess.run([str(compiler), *[x for path in includes for x in ['-I', path]], '-c', 'forged.ml'],
                            cwd=root, env=clean, capture_output=True, text=True, timeout=30)
    require(result.returncode != 0 and 'Http_kit_router.pattern' in result.stderr, "test_router_consumer.py: result.returncode != 0 and 'Http_kit_router.pattern' in result.stderr")
    require('Unbound module' not in result.stderr, "test_router_consumer.py: 'Unbound module' not in result.stderr")
print('PASS: installed pure router in native/bytecode; opaque pattern cannot be forged')
