#!/usr/bin/env python3
"""mise owns opam; opam owns Dune; Dune owns the locked project toolchain."""
import os
from pathlib import Path
import subprocess
import sys
from dune_env import ROOT, MANIFEST, configuration, require_lock, command

version = sys.argv[1] if len(sys.argv) == 2 else '5.5.0'
if version not in MANIFEST['compilers'] or len(sys.argv) > 2:
    sys.exit('usage: bootstrap.py [5.2.1|5.5.0]')
# Resolve through mise, never an unrelated opam or Dune on the caller's PATH.
opam = subprocess.check_output(['mise', 'which', 'opam'], cwd=ROOT, text=True).strip()
env = dict(os.environ, OPAMROOT=str(ROOT / '.toolchain/opam'),
           OPAMLOGS=str(ROOT / '.toolchain/opam-logs'))
Path(env['OPAMLOGS']).mkdir(parents=True, exist_ok=True)


def run(*args):
    subprocess.run([opam, *args], env=env, cwd=ROOT, check=True)


if not (Path(env['OPAMROOT']) / 'config').exists():
    run('init', '--bare', '--disable-sandboxing', '--no-setup', '-y',
        'default', 'git+' + MANIFEST['opam_repository'])
else:
    run('repository', 'set-url', 'default',
        'git+' + MANIFEST['opam_repository'], '--all-switches', '-y')
switch = 'dune-bootstrap'
switch_dir = Path(env['OPAMROOT']) / switch
if not (switch_dir / 'bin/ocamlc').exists():
    run('switch', 'create', switch, 'ocaml-base-compiler.5.5.0', '-y', '--jobs=4')
run('install', '--switch=' + switch, '-y', '--jobs=4', 'dune.' + MANIFEST['dune'])

# Keep the stable launcher path, but execute the opam-owned binary directly.
binary = ROOT / '.toolchain/bin/dune'
binary.parent.mkdir(parents=True, exist_ok=True)
temporary = binary.with_name('dune.new')
temporary.unlink(missing_ok=True)
temporary.symlink_to(Path('../opam') / switch / 'bin/dune')
temporary.replace(binary)

dune, env, lock = configuration(version)
require_lock(lock)
subprocess.run(command(dune, env, ['pkg', 'validate-lockdir', lock.name]), env=env, cwd=ROOT, check=True)
subprocess.run(command(dune, env, ['build', '-j', '4', '@pkg-install']), env=env, cwd=ROOT, check=True)
print(f'Ready: HARNESS_COMPILER={version} tools/harness run --tier fast')
