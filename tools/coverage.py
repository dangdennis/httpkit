#!/usr/bin/env python3
"""Measure first-party points with a dedicated compatible compiler/PPX lock."""
from checks import require
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from dune_env import ROOT, configuration, require_lock
from evidence import source_hash, record

dune,env,_=configuration('5.5.0');require_lock(ROOT/'coverage.lock');digest=source_hash()
out=ROOT/'_artifacts/coverage';out.mkdir(parents=True,exist_ok=True)
run_dir=Path(tempfile.mkdtemp(prefix='run-',dir=out));env['BISECT_FILE']=str(run_dir/'point')
flags=['--workspace='+str(ROOT/'dune-workspace.coverage'),'--build-dir=_build-coverage']
def run(args):
    return subprocess.check_output([dune,args[0],*flags,*args[1:]],cwd=ROOT,env=env,text=True,stderr=subprocess.STDOUT,timeout=1800)
log=run(['runtest','--instrument-with','bisect_ppx','--force','test/core','test/http1','test/engine','test/adapter','test/middleware','test/router'])
(run_dir/'tests.log').write_text(log)
for name in ['http1_fuzz','engine_fuzz','release_fuzz','adapter_fuzz']:
    log=run(['exec','--instrument-with','bisect_ppx','./fuzz/'+name+'.exe','--','-r','10000','-s','42'])
    (run_dir/(name+'.log')).write_text(log)
summary=run(['exec','--','bisect-ppx-report','summary','--coverage-path='+str(run_dir),'--per-file'])
(run_dir/'summary.txt').write_text(summary)
run(['exec','--','bisect-ppx-report','html','--coverage-path='+str(run_dir),'-o',str(run_dir/'html')])
run(['exec','--','bisect-ppx-report','coveralls','--coverage-path='+str(run_dir),str(run_dir/'lines.json')])
files=[]
for line in summary.splitlines():
    match=re.match(r'\s*[\d.]+\s*%\s+(\d+)/(\d+)\s+(lib/\S+\.ml)',line)
    if match:files.append({'file':match[3],'visited':int(match[1]),'total':int(match[2])})
required={str(p.relative_to(ROOT)) for layer in ['core','http1','engine'] for p in (ROOT/'lib'/layer).glob('*.ml')}
# This file is exclusively module aliases, with no executable expressions.
required.remove('lib/core/httpkit_core.ml')
missing=sorted(required-{f['file'] for f in files})
selected=[f for f in files if f['file'] in required]
visited=sum(f['visited'] for f in selected);total=sum(f['total'] for f in selected)
require(total>0 and source_hash()==digest, 'empty coverage or sources changed')
record('coverage.json',{'status':'PASS','compiler':'5.5.0','tool_revision':'7061d643ff492b0045796357ee6917ded21fb1f0',
 'metric':'instrumented points, not branches','visited':visited,'total':total,'percent':100*visited/total,
 'missing_files':missing,'files':files,'report_directory':str(run_dir),
 'exclusions':[{'file':'lib/core/httpkit_core.ml','reason':'Module aliases only; no executable expressions.'}]})
print(summary)
print(json.dumps({'percent':100*visited/total,'missing_files':missing,'report_directory':str(run_dir)},indent=2))
