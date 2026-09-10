#!/usr/bin/env python3
"""Bootstrap Dune only with opam; Dune installs the locked project toolchain."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
from dune_env import ROOT, MANIFEST, configuration, require_lock, command

version = sys.argv[1] if len(sys.argv) == 2 else '5.5.0'
if version not in MANIFEST['compilers'] or len(sys.argv) > 2:
    sys.exit('usage: bootstrap.py [5.2.1|5.5.0]')
binary = ROOT / '.toolchain/bin/dune'
binary.parent.mkdir(parents=True, exist_ok=True)


def correct_dune(path):
    return path and subprocess.run([str(path), '--version'], capture_output=True,
                                   text=True, check=True).stdout.strip() == MANIFEST['dune']


if not binary.exists():
    candidate = shutil.which('dune')
    if correct_dune(candidate):
        shutil.copy2(candidate, binary)
    else:
        env = dict(os.environ, OPAMROOT=str(ROOT / '.toolchain/opam'),
                   OPAMLOGS=str(ROOT / '.toolchain/opam-logs'))
        Path(env['OPAMLOGS']).mkdir(parents=True, exist_ok=True)
        def run(*args):
            subprocess.run(args, env=env, cwd=ROOT, check=True)
        if not (Path(env['OPAMROOT']) / 'config').exists():
            run('opam', 'init', '--bare', '--disable-sandboxing', '--no-setup', '-y',
                'default', 'git+' + MANIFEST['opam_repository'])
        else:
            run('opam', 'repository', 'set-url', 'default',
                'git+' + MANIFEST['opam_repository'], '--all-switches', '-y')
        switch = 'dune-bootstrap'
        switch_dir = Path(env['OPAMROOT']) / switch
        if not (switch_dir / 'bin/ocamlc').exists():
            run('opam', 'switch', 'create', switch, 'ocaml-base-compiler.5.5.0', '-y', '--jobs=4')
        run('opam', 'install', '--switch=' + switch, '-y', '--jobs=4',
            'dune.' + MANIFEST['dune'])
        shutil.copy2(switch_dir / 'bin/dune', binary)

dune, env, lock = configuration(version)
require_lock(lock)
subprocess.run(command(dune, env, ['pkg', 'validate-lockdir', lock.name]), env=env, cwd=ROOT, check=True)
subprocess.run(command(dune, env, ['build', '-j', '4', '@pkg-install']), env=env, cwd=ROOT, check=True)
print(f'Ready: HARNESS_COMPILER={version} tools/harness run --tier fast')
