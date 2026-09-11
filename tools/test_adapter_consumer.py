#!/usr/bin/env python3
"""Install each runtime independently and execute the shared-handler examples."""
from checks import require
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from dune_env import ROOT, configuration, command

dune, env, _ = configuration()
def locked(args):
    return subprocess.check_output(command(dune, env, args), cwd=ROOT, env=env, text=True, timeout=1800).strip()
compiler = Path(locked(['exec', '--', 'sh', '-c', 'command -v ocamlc'])).resolve()
for adapter, runtime in [('eio', 'eio_main'), ('lwt', 'lwt.unix')]:
    with tempfile.TemporaryDirectory(prefix='http-kit-'+adapter+'-consumer-') as directory:
        root = Path(directory)
        clean = {k:v for k,v in env.items() if not k.startswith(('OCAML','CAML','DUNE'))}
        clean['PATH'] = str(compiler.parent)+os.pathsep+clean['PATH']
        paths = {Path(p) for p in locked(['exec','--','ocamlfind','query','-recursive','-format','%d',runtime,'ipaddr','mtime.clock.os']).splitlines()}
        # Copy package roots once, preserving sublibrary META paths and C stubs.
        paths = {p for p in paths if not any(q != p and q in p.parents for q in paths) and compiler.parent.parent not in p.parents}
        deps = root/'deps'; deps.mkdir()
        for path in paths:
            shutil.copytree(path, deps/path.name)
            if (path.parent/'stublibs').is_dir():
                shutil.copytree(path.parent/'stublibs',deps/'stublibs',dirs_exist_ok=True)
        forbidden = 'lwt' if adapter=='eio' else 'eio'
        require(not (deps/forbidden).exists(), 'opposite runtime in dependency closure')
        clean['OCAMLPATH'] = str(deps)
        stage = root/'source'; stage.mkdir()
        for package in ['core','http1','engine',adapter]:
            shutil.copytree(ROOT/'lib'/package, stage/package)
            shutil.copy2(ROOT/f'http-kit-{package}.opam',stage/f'http-kit-{package}.opam')
        def project(path):
            (path/'dune-project').write_text('(lang dune 3.24)\n(name isolated)\n')
            (path/'dune-workspace').write_text('(lang dune 3.24)\n(pkg disabled)\n')
        project(stage)
        def run(cwd,args):
            result = subprocess.run([dune,*args],cwd=cwd,env=clean,capture_output=True,timeout=180)
            require(result.returncode==0, (args,result.stdout,result.stderr))
        prefix=root/'installed'
        run(stage,['build','@install'])
        run(stage,['install','--prefix',str(prefix),*[f'http-kit-{p}' for p in ['core','http1','engine',adapter]]])
        clean['OCAMLPATH']=str(prefix/'lib')+os.pathsep+str(deps)
        clean['CAML_LD_LIBRARY_PATH']=os.pathsep.join(str(p.parent) for p in deps.rglob('dll*.so'))
        consumer=root/'consumer';consumer.mkdir();project(consumer)
        for name in ['transform.ml',adapter+'_example.ml']:
            shutil.copy2(ROOT/'examples/runtime'/name,consumer/name)
        example = consumer/(adapter+'_example.ml')
        example.write_text(example.read_text() + '\nlet configured_server ~clock ~accept ~on_error handler = Http_kit_'+adapter+'.serve_connections ~output_limit:4096 ~informational_limit:2 ~clock ~accept ~on_error handler\nlet _ = Http_kit_'+adapter+'.failure_to_string (Engine Http_kit_engine.Invalid_command)\n')
        (consumer/'dune').write_text(f'(executable (name {adapter}_example) (modes byte exe) (libraries http-kit-core http-kit-{adapter} {runtime}))\n')
        run(consumer,['build',adapter+'_example.exe',adapter+'_example.bc'])
        for executable in [[str(consumer/f'_build/default/{adapter}_example.exe')],
                           [str(compiler.with_name('ocamlrun')),str(consumer/f'_build/default/{adapter}_example.bc')]]:
            result=subprocess.run(executable,cwd=consumer,env=clean,capture_output=True,timeout=15)
            require(result.returncode==0 and result.stdout==b'Hello /\n', (executable,result.stdout,result.stderr))
        (consumer/'opposite.ml').write_text('let _ = '+('Lwt.return_unit' if adapter=='eio' else 'Eio.Fiber.yield')+'\n')
        (consumer/'dune').write_text(f'(executable (name opposite) (modules opposite) (libraries http-kit-{adapter}))\n')
        result=subprocess.run([dune,'build','opposite.exe'],cwd=consumer,env=clean,capture_output=True,text=True,timeout=30)
        require(result.returncode!=0 and 'Unbound module' in result.stderr, result.stderr)
print('PASS: Eio/Lwt separately installed; shared pure handler; native/bytecode sockets; opposite runtime unavailable')
