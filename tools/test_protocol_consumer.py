#!/usr/bin/env python3
"""Install protocol primitives with only declared deps; run an independent parser."""
import http.client
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from dune_env import ROOT, configuration, command

dune, env, _ = configuration()
def locked(args):
    return subprocess.check_output(command(dune,env,args),cwd=ROOT,env=env,text=True,timeout=1800).strip()
compiler = Path(locked(['exec','--','sh','-c','command -v ocamlc'])).resolve()
dependencies = [Path(p) for p in locked(['exec','--','ocamlfind','query','-recursive','-format','%d','ipaddr']).splitlines()]
with tempfile.TemporaryDirectory(prefix='http-kit-protocol-consumer-') as directory:
    root=Path(directory)
    clean={k:v for k,v in env.items() if not k.startswith(('OCAML','CAML','DUNE'))}
    clean['PATH']=str(compiler.parent)+os.pathsep+clean['PATH']
    deps=root/'deps';deps.mkdir()
    for path in dependencies:
        shutil.copytree(path,deps/path.name)
    clean['OCAMLPATH']=str(deps)
    stage=root/'source';stage.mkdir()
    for package in ['core','http1','engine']:
        shutil.copytree(ROOT/'lib'/package,stage/package)
        shutil.copy2(ROOT/f'http-kit-{package}.opam',stage/f'http-kit-{package}.opam')
    (stage/'dune-project').write_text('(lang dune 3.24)\n(name protocol-install)\n')
    (stage/'dune-workspace').write_text('(lang dune 3.24)\n(pkg disabled)\n')
    prefix=root/'installed'
    def run(cwd,args):
        result=subprocess.run([dune,*args],cwd=cwd,env=clean,capture_output=True,timeout=120)
        assert result.returncode==0,(args,result.stdout,result.stderr)
        return result.stdout
    run(stage,['build','@install'])
    run(stage,['install','--prefix',str(prefix),'http-kit-core','http-kit-http1','http-kit-engine'])
    clean['OCAMLPATH']=str(prefix/'lib')+os.pathsep+str(deps)
    consumer=root/'consumer';consumer.mkdir()
    (consumer/'dune-project').write_text('(lang dune 3.24)\n(name consumer)\n')
    (consumer/'dune-workspace').write_text('(lang dune 3.24)\n(pkg disabled)\n')
    (consumer/'dune').write_text('(executable (name consumer) (modes byte exe) (libraries http-kit-core http-kit-http1))\n')
    shutil.copy2(ROOT/'test/api/http1/consumer.ml',consumer/'consumer.ml')
    run(consumer,['build','consumer.exe','consumer.bc'])
    native=subprocess.check_output([str(consumer/'_build/default/consumer.exe')],timeout=30)
    bytecode=subprocess.check_output([str(compiler.with_name('ocamlrun')),str(consumer/'_build/default/consumer.bc')],timeout=30)
    assert native==bytecode, 'instrumentation-independent consumer mismatch'
    class Socket:
        def makefile(self,*args): return io.BytesIO(native)
    response=http.client.HTTPResponse(Socket())
    response.begin()
    assert response.status==200 and response.read()==b'abc'
    assert [v for n,v in response.getheaders() if n.lower()=='set-cookie']==['a=1','b=2']
    # A second consumer links the engine directly, with no runtime adapters.
    shutil.copy2(ROOT/'test/api/engine/consumer.ml',consumer/'consumer.ml')
    (consumer/'dune').write_text('(executable (name consumer) (modes byte exe) (libraries http-kit-core http-kit-engine))\n')
    run(consumer,['build','consumer.exe','consumer.bc'])
    engine_wire=subprocess.check_output([str(consumer/'_build/default/consumer.exe')],timeout=30)
    assert engine_wire == b'HTTP/1.1 200 \r\ncontent-length: 3\r\n\r\nabc'
    assert subprocess.check_output([str(compiler.with_name('ocamlrun')),str(consumer/'_build/default/consumer.bc')],timeout=30)==engine_wire
    (consumer/'dune').write_text('(executable (name consumer) (libraries http-kit-core http-kit-http1))\n')
    (consumer/'consumer.ml').write_text('let forge (m:Http_kit_http1.metadata) = {m with persistent=true}\n')
    result=subprocess.run([dune,'build','consumer.exe'],cwd=consumer,env=clean,capture_output=True,text=True,timeout=30)
    assert result.returncode!=0 and 'private' in result.stderr, result.stderr
print('PASS: installed HTTP/1 and engine bytecode/native consumers, private metadata, Python stdlib response reference')
