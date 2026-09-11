#!/usr/bin/env python3
"""Exercise an installed package, with only its include directory and stdlib."""
from checks import require
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
from dune_env import ROOT, configuration, command

dune, env, _ = configuration()

def run(args, *, expected=True):
    result = subprocess.run(command(dune, env, args), cwd=ROOT, env=env,
                            capture_output=True, text=True, timeout=1800)
    if (result.returncode == 0) != expected:
        raise RuntimeError(result.stdout + result.stderr)
    return result

run(['build', 'http-kit-core.install'])
with tempfile.TemporaryDirectory(prefix='http-kit-consumer-') as directory:
    root = Path(directory)
    prefix = root / 'installed'
    # Resolve only the compiler through Dune; invoke it outside the checkout with
    # a clean OCaml environment. No build-tree include paths or findlib discovery.
    compiler = run(['exec', '--', 'sh', '-c', 'command -v ocamlc']).stdout.strip()
    compiler = str(Path(compiler).resolve())
    clean = {k: v for k, v in env.items() if not k.startswith(('OCAML', 'CAML', 'DUNE'))}
    clean['PATH'] = str(Path(compiler).parent) + os.pathsep + clean['PATH']
    # Dune 3.24 package mode has no `install` command. Stage just core sources in
    # a separate, package-disabled project; the compiler still comes from our lock.
    # With no other sources or third-party libraries available, build + install
    # also verifies that core's declared stdlib-only dependency closure is real.
    staging = root / 'package'
    staging.mkdir()
    shutil.copytree(ROOT / 'lib/core', staging / 'core')
    shutil.copy2(ROOT / 'http-kit-core.opam', staging / 'http-kit-core.opam')
    (staging / 'dune-project').write_text('(lang dune 3.24)\n(name http-kit-core)\n')
    (staging / 'dune-workspace').write_text('(lang dune 3.24)\n(pkg disabled)\n')
    for args in [['build', '@install'], ['install', 'http-kit-core', '--prefix', str(prefix)]]:
        result = subprocess.run([dune, *args], cwd=staging, env=clean,
                                capture_output=True, text=True, timeout=120)
        require(result.returncode == 0, result.stdout + result.stderr)
    library = prefix / 'lib/http-kit-core'
    require(library.is_dir(), 'core installation missing')
    require(sorted(p.name for p in (prefix / 'lib').iterdir()) == ['http-kit-core'], 'unrelated package installed')
    for source in (ROOT / 'test/api').glob('*.ml'):
        shutil.copy2(source, root / source.name)
    examples = re.findall(r'\{\[(.*?)\]\}', (ROOT / 'lib/core/doc/index.mld').read_text(), re.S)
    require(len(examples) == 1, 'documentation example inventory changed')
    (root / 'documentation.ml').write_text(examples[0] + '''
let () =
  assert (Result.is_ok (request "/"));
  assert (Result.is_error (request "/ bad"))
''')
    compile_args = [compiler, '-I', str(library)]
    def compile_file(name, extra):
        return subprocess.run(compile_args + extra + [name], cwd=root, env=clean,
                              capture_output=True, text=True, timeout=30)
    result = compile_file('consumer.ml', [str(library / 'http_kit_core.cma'), '-o', 'consumer'])
    require(result.returncode == 0, result.stderr)
    # Invoke ocamlrun explicitly: the compiler's absolute runtime path can belong
    # to a package sandbox; do not depend on a globally installed interpreter.
    runtime = str(Path(compiler).with_name('ocamlrun'))
    subprocess.run([runtime, str(root / 'consumer')], cwd=root, env=clean, check=True, timeout=30)
    result = compile_file('documentation.ml', [str(library / 'http_kit_core.cma'), '-o', 'documentation'])
    require(result.returncode == 0, result.stderr)
    subprocess.run([runtime, str(root / 'documentation')], cwd=root, env=clean, check=True, timeout=30)
    result = subprocess.run([str(Path(compiler).with_name('ocamlopt')), '-I', str(library),
                             str(library / 'http_kit_core.cmxa'), 'consumer.ml', '-o', 'consumer-native'],
                            cwd=root, env=clean, capture_output=True, text=True, timeout=30)
    require(result.returncode == 0, result.stderr)
    subprocess.run([str(root / 'consumer-native')], cwd=root, env=clean, check=True, timeout=30)
    negative = {
        'forged_method.ml': 'Method.t', 'forged_header.ml': 'Name.t',
        'forged_value.ml': 'Value.t', 'forged_target.ml': 'Target.t',
        'forged_status.ml': 'Status.t', 'private_helper.ml': 'Unbound module',
        'private_harness.ml': 'Unbound module',
    }
    for name, diagnostic in negative.items():
        result = compile_file(name, ['-c'])
        require(result.returncode != 0 and diagnostic in result.stderr, (name, result.stderr))
print('PASS: installed bytecode/native consumers, executable odoc example, five opaque constructors, private helper and harness isolation')
