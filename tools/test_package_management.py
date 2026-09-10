#!/usr/bin/env python3
"""Check that Dune locks are used and invalid/missing solutions fail closed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from dune_env import ROOT, configuration, command

dune, configured_env, _ = configuration()
for version, lock in [('5.5.0', 'dune.lock')]:
    _, target_env, _ = configuration(version)
    assert command(dune, target_env, ['pkg', 'lock'])[-1] == lock
original_env = dict(os.environ)
try:
    os.environ.clear()
    os.environ.update(configured_env)
    assert configuration()[1] == configured_env, 'toolchain environment must be idempotent'
finally:
    os.environ.clear()
    os.environ.update(original_env)
with tempfile.TemporaryDirectory(prefix='http-kit-lock-') as directory:
    root = Path(directory)
    for name in ['dune-project', 'dune-workspace', 'http-kit-harness.opam', 'http-kit-core.opam']:
        shutil.copy2(ROOT / name, root / name)
    for name in ['dune.lock']:
        shutil.copytree(ROOT / name, root / name)
    for name in ['tools', 'toolchain', '.toolchain/bin']:
        (root / name).mkdir(parents=True)
    for name in ['dune-pkg', 'dune_env.py']:
        shutil.copy2(ROOT / 'tools' / name, root / 'tools' / name)
    shutil.copy2(ROOT / 'toolchain/manifest.json', root / 'toolchain/manifest.json')
    (root / '.toolchain/bin/dune').symlink_to(dune)

    def run(version, *args, success=True):
        result = subprocess.run([str(root / 'tools/dune-pkg'), *args], cwd=root,
            env=dict(os.environ, HARNESS_COMPILER=version, DUNE_CONFIG__PKG='disabled'),
            capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == success, (args, result.stdout, result.stderr)
        return result.stdout + result.stderr

    for version, lock in [('5.5.0', 'dune.lock')]:
        run(version, 'pkg', 'enabled')
        run(version, 'pkg', 'validate-lockdir', lock)
    project = root / 'dune-project'
    project.write_text(project.read_text().replace('(yojson (= 3.0.0))', '(yojson (= 0.0.0))'))
    run('5.5.0', 'pkg', 'validate-lockdir', success=False)
    shutil.rmtree(root / 'dune.lock')
    error = run('5.5.0', 'build', success=False)
    assert 'Missing dune.lock' in error
    assert not (root / 'dune.lock').exists()
    run('invalid', 'build', success=False)
    assert 'HARNESS_COMPILER must be 5.5.0' in run('5.2.1', 'build', success=False)
print('PASS: package management enabled, 5.5.0 lock valid, stale/missing locks and invalid compilers rejected')
