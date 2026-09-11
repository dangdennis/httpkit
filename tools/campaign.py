#!/usr/bin/env python3
"""Retained AFL campaigns. A smoke run never satisfies the eight-hour gate."""
from checks import require
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from dune_env import ROOT, configuration, command
from evidence import record, source_hash

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--seconds',type=int,default=30)
    parser.add_argument('--target',default='all')
    args=parser.parse_args()
    targets=json.loads((ROOT/'toolchain/fuzz-targets.json').read_text())
    if args.seconds<1:parser.error('seconds must be positive')
    if args.target!='all':
        targets=[t for t in targets if t['name']==args.target]
        if not targets:parser.error('unknown target')
    dune,env,_=configuration();version=env['HARNESS_COMPILER'];digest=source_hash()
    afl=ROOT/'.toolchain/afl';revision=(ROOT/'toolchain/afl.version').read_text().split()[2]
    require(subprocess.check_output(['git','-C',str(afl),'rev-parse','HEAD'],text=True).strip()==revision, "campaign.py: subprocess.check_output(['git','-C',str(afl),'rev-parse','HEAD'],text=True).strip()==revision")
    subprocess.run(['git','-C',str(afl),'diff','--quiet','HEAD','--'],check=True)
    env.update(AFL_SKIP_CPUFREQ='1',AFL_NO_AFFINITY='1',AFL_MAP_SIZE='65536',AFL_CRASH_EXITCODE='2',
               AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES='1',AFL_NO_UI='1')
    env.pop('HTTP_KIT_FUZZ_CASE',None)
    build='_build-fuzz-pkg-'+version
    binaries=sorted({'fuzz/'+t['binary']+'.exe' for t in targets})
    for flags in [[],['--profile','fuzz','--build-dir',build]]:
        subprocess.run(command(dune,env,['build',*flags,'-j','4',*binaries]),cwd=ROOT,env=env,check=True,timeout=1800)
    base=ROOT/'_artifacts/campaigns';base.mkdir(parents=True,exist_ok=True)
    directory=Path(tempfile.mkdtemp(prefix=digest[:12]+'-',dir=base))
    results=[]
    for target in targets:
        name=target['name'];target_env=dict(env)
        if target['case'] is not None:target_env['HTTP_KIT_FUZZ_CASE']=target['case']
        seeds=directory/(name+'-seeds');seeds.mkdir()
        # Crowbar's selector byte plus terminated bytes. Every selected target
        # gets a seed that reaches its intended first-party state.
        (seeds/'valid').write_bytes(b'\0'+target['seed'].encode()+b'\0')
        (seeds/'controls').write_bytes(b'\0\x03\x02\x01\x02\0')
        binary=ROOT/build/'default/fuzz'/ (target['binary']+'.exe')
        plain=ROOT/f'_build-pkg-{version}/default/fuzz'/(target['binary']+'.exe')
        output=directory/name;started=time.monotonic()
        with (directory/(name+'.log')).open('wb') as log:
            result=subprocess.run([str(afl/'afl-fuzz'),'-V',str(args.seconds),'-m','512','-t','2000',
                '-i',str(seeds),'-o',str(output),'--',str(binary),'@@'],cwd=ROOT,env=target_env,stdout=log,stderr=subprocess.STDOUT,timeout=args.seconds+120)
        require(result.returncode==0, ('AFL failed; logs and corpus retained',name,directory))
        findings=[p for p in output.rglob('id:*') if p.parent.name in ('crashes','hangs')]
        require(not findings, ('untriaged findings retained',name,[str(p) for p in findings]))
        stats_files=list(output.rglob('fuzzer_stats'));require(len(stats_files)==1, 'campaign.py: len(stats_files)==1')
        stats={k.strip():v.strip() for k,v in (line.split(':',1) for line in stats_files[0].read_text().splitlines() if ':' in line)}
        seconds=int(stats['run_time']);executions=int(stats['execs_done'])
        require(seconds>=max(1,args.seconds-2) and executions>=10, ('incomplete campaign',name,stats))
        corpus=sorted(p for p in output.rglob('id:*') if p.parent.name=='queue')
        # Replay every retained queue entry without instrumentation. A timeout
        # or failure is evidence failure, not a silently skipped testcase.
        with (directory/(name+'-replay.log')).open('wb') as log:
            for case in corpus:
                subprocess.run([str(plain),str(case)],cwd=ROOT,env=target_env,check=True,stdout=log,stderr=subprocess.STDOUT,timeout=5)
        row={'target':name,'seconds_requested':args.seconds,'seconds_executed':seconds,'wall_seconds':time.monotonic()-started,
             'executions':executions,'uninstrumented_replays':len(corpus),'findings':len(findings),'directory':str(output)}
        results.append(row)
        require(source_hash()==digest, 'sources changed during target; refusing to record evidence')
        record('campaign-'+name+'.json',{'status':'PASS','compiler':version,'afl_revision':revision,**row})
        print(json.dumps(row),flush=True)
    require(source_hash()==digest, 'sources changed during campaign; evidence invalid')
    record('campaign-summary.json',{'status':'PASS','compiler':version,'afl_revision':revision,'results':results,
                                   'scope':'release-duration' if args.seconds>=28800 else 'smoke'})
if __name__=='__main__':main()
