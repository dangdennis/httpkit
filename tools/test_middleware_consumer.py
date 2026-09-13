#!/usr/bin/env python3
"""Verify the documented styles and rejected context transitions after install."""
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
with tempfile.TemporaryDirectory(prefix='httpkit-middleware-') as directory:
    root = Path(directory)
    source = root / 'source'; source.mkdir()
    for name in ['core', 'middleware']:
        shutil.copytree(ROOT / 'lib' / name, source / name)
        shutil.copy2(ROOT / f'httpkit-{name}.opam', source)
    (source / 'dune-project').write_text('(lang dune 3.24)\n(name installed-middleware)\n')
    (source / 'dune-workspace').write_text('(lang dune 3.24)\n(pkg disabled)\n')
    prefix = root / 'installed'
    for args in [['build', '@install'], ['install', '--prefix', str(prefix),
                 'httpkit-core', 'httpkit-middleware']]:
        subprocess.run([dune, *args], cwd=source, env=clean, check=True,
                       capture_output=True, timeout=120)
    require(sorted(p.name for p in (prefix / 'lib').iterdir()) == ['httpkit-core', 'httpkit-middleware'], "test_middleware_consumer.py: sorted(p.name for p in (prefix / 'lib').iterdir()) == ['httpkit-core', 'httpkit-middleware']")
    includes = [str(prefix / 'lib' / name) for name in ['httpkit-core', 'httpkit-middleware']]
    for mode, tool, extension in [('byte', compiler, 'cma'), ('native', compiler.with_name('ocamlopt'), 'cmxa')]:
        example = root / 'styles.ml'
        shutil.copy2(ROOT / 'examples/middleware/styles.ml', example)
        args = [str(tool), *[x for path in includes for x in ['-I', path]],
                str(Path(includes[0]) / ('httpkit_core.' + extension)),
                str(Path(includes[1]) / ('httpkit_middleware.' + extension)),
                'styles.ml', '-o', 'styles-' + mode]
        subprocess.run(args, cwd=root, env=clean, check=True, capture_output=True, timeout=30)
        exe = str(root / ('styles-' + mode))
        run = [str(compiler.with_name('ocamlrun')), exe] if mode == 'byte' else [exe]
        output = subprocess.check_output(run, cwd=root, env=clean, timeout=30)
        require(output == b'PASS: basic, contextual and transition middleware\n', "test_middleware_consumer.py: output == b'PASS: basic, contextual and transition middleware\\n'")
    for fixture in sorted((ROOT / 'test/api/middleware').glob('*.ml')):
        shutil.copy2(fixture, root / fixture.name)
        result = subprocess.run([str(compiler), *[x for path in includes for x in ['-I', path]],
                                 '-c', fixture.name], cwd=root, env=clean,
                                capture_output=True, text=True, timeout=30)
        require(result.returncode != 0 and 'expected of type' in result.stderr, (fixture.name, result.stderr))
        require('Unbound module' not in result.stderr, "test_middleware_consumer.py: 'Unbound module' not in result.stderr")
print('PASS: installed middleware styles in native/bytecode; mismatched, skipped and reversed contexts rejected')
