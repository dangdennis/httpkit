#!/usr/bin/env python3
"""Reproduce the historical request timeout without waiving its classification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from checks import require
from dune_env import ROOT, configuration, command
from evidence import source_hash


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--replays',type=int,default=100)
    parser.add_argument('--afl-seconds',type=int,default=30)
    parser.add_argument('--rounds',type=int,default=3)
    args=parser.parse_args()
    require(min(args.replays,args.afl_seconds,args.rounds)>0,'positive budgets required')
    case=ROOT/'fuzz/corpus/request/retained-timeout.seed'
    require(hashlib.sha256(case.read_bytes()).hexdigest()=='d8e43ca80ca7b49d20b83727a978efbf1b10eaabed29e0aeb2c2ff9ceabd3a3b','retained input changed')
    digest=source_hash();dune,env,_=configuration();version=env['HARNESS_COMPILER']
    build='_build-fuzz-pkg-'+version
    for flags in [[],['--profile','fuzz','--build-dir',build]]:
        subprocess.run(command(dune,env,['build',*flags,'fuzz/http1_fuzz.exe']),cwd=ROOT,env=env,check=True,timeout=1800)
    directory=ROOT/'_artifacts/personal'/f'timeout-{time.time_ns()}';directory.mkdir(parents=True)
    env.update(HTTP_KIT_FUZZ_CASE='request',AFL_SKIP_CPUFREQ='1',AFL_NO_AFFINITY='1',
               AFL_MAP_SIZE='65536',AFL_CRASH_EXITCODE='2',AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES='1',AFL_NO_UI='1')
    result=dict(source_sha256=digest,input_sha256=hashlib.sha256(case.read_bytes()).hexdigest(),
                classification='UNRESOLVED',direct=[],afl=[],directory=str(directory))
    report=directory/'report.json'
    def save():report.write_text(json.dumps(result,indent=2)+'\n')
    save()
    try:
        for folder in ['_build-pkg-'+version,build]:
            binary=ROOT/folder/'default/fuzz/http1_fuzz.exe'
            for i in range(args.replays):
                start=time.monotonic()
                p=subprocess.run([str(binary),str(case)],env=env,capture_output=True,timeout=2)
                result['direct'].append(dict(build=folder,iteration=i,seconds=time.monotonic()-start,exit=p.returncode,output=p.stdout.decode(errors='replace')))
                require(p.returncode==0,('direct replay failed',folder,i,p.stderr))
        seeds=directory/'seeds';seeds.mkdir();(seeds/'retained').write_bytes(case.read_bytes())
        afl=ROOT/'.toolchain/afl'
        revision=subprocess.check_output(['git','-C',str(afl),'rev-parse','HEAD'],text=True).strip()
        require(revision==(ROOT/'toolchain/afl.version').read_text().split()[2],'AFL revision mismatch')
        subprocess.run(['git','-C',str(afl),'diff','--quiet','HEAD','--'],check=True)
        result['afl_revision']=revision
        for i in range(args.rounds):
            output=directory/f'round-{i}'
            cmd=[str(afl/'afl-fuzz'),'-V',str(args.afl_seconds),'-m','512','-t','2000','-s',str(42+i),
                 '-i',str(seeds),'-o',str(output),'--',str(ROOT/build/'default/fuzz/http1_fuzz.exe'),'@@']
            with (directory/f'afl-{i}.log').open('wb') as log:
                p=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=args.afl_seconds+120)
            findings=[str(p) for p in output.rglob('id:*') if p.parent.name in ['hangs','crashes']]
            result['afl'].append(dict(command=cmd,exit=p.returncode,findings=findings))
            save();require(p.returncode==0 and not findings,('AFL failure/finding',result['afl'][-1]))
        require(source_hash()==digest,'source changed during investigation')
        result['replay_status']='PASS'
        result['interpretation']='Not reproduced under direct execution or repeated original AFL limits. Historical cause remains unproven.'
        save();print(json.dumps(dict(report=str(report),classification=result['classification'],replay_status='PASS')))
    except BaseException as exn:
        result['replay_status']='FAIL';result['error']=repr(exn);save();raise


if __name__=='__main__':main()
