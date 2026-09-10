"""One Dune package-management environment for build, test, and fuzz commands."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / 'toolchain/manifest.json').read_text())


def configuration(version=None):
    version = version or os.environ.get('HARNESS_COMPILER', '5.5.0')
    if version not in MANIFEST['compilers']:
        raise ValueError('HARNESS_COMPILER must be 5.2.1 or 5.5.0')
    lock = 'dune.lock' if version == '5.5.0' else 'dune.5.2.lock'
    local_bin = str(ROOT / '.toolchain/bin')
    path = [part for part in os.environ.get('PATH', '').split(os.pathsep) if part != local_bin]
    env = dict(os.environ, HARNESS_COMPILER=version,
               PATH=os.pathsep.join([local_bin, *path]),
               XDG_CACHE_HOME=str(ROOT / '.toolchain/cache'))
    for name in ['DUNE_WORKSPACE', 'DUNE_BUILD_DIR', 'OCAMLPATH', 'OCAMLLIB', 'CAML_LD_LIBRARY_PATH',
                 'DUNE_CONFIG__PKG', 'DUNE_CONFIG__PORTABLE_LOCK_DIR',
                 'DUNE_CONFIG__RELOCATABLE_COMPILER']:
        env.pop(name, None)
    dune = ROOT / '.toolchain/bin/dune'
    if not dune.is_file():
        raise RuntimeError('Run python3 tools/bootstrap.py to install Dune')
    actual = subprocess.check_output([str(dune), '--version'], text=True).strip()
    if actual != MANIFEST['dune']:
        raise RuntimeError(f'Expected Dune {MANIFEST["dune"]}, found {actual}')
    return str(dune), env, ROOT / lock


def require_lock(lock):
    if not (lock / 'lock.dune').is_file():
        raise RuntimeError(f'Missing {lock.name}; restore it or explicitly run tools/dune-pkg pkg lock')


def command(dune, env, args):
    # Use CLI flags: workspace/build-dir environment variables can leak into
    # nested Dune invocations while building third-party packages.
    version = env['HARNESS_COMPILER']
    workspace = 'dune-workspace' if version == '5.5.0' else 'dune-workspace.5.2'
    flags = ['--workspace=' + str(ROOT / workspace)]
    if '--build-dir' not in args and not any(a.startswith('--build-dir=') for a in args):
        flags += ['--build-dir=_build-pkg-' + version]
    split = 2 if args and args[0] == 'pkg' else 1
    return [dune, *args[:split], *flags, *args[split:]]
