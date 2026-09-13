#!/usr/bin/env python3
"""Run the approved local personal-use validation on an unchanged checkout.

Reports retain the historical timeout as unresolved. Passing experiments do not
implicitly grant public-release approval or a personal-use readiness tag.
"""
import argparse
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import time
from evidence import ROOT, source_hash
from checks import require


def stop_process(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--long', action='store_true', help='also run nine 30-minute campaigns and a two-hour soak')
    args = parser.parse_args()
    digest = source_hash()
    commit = subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip()
    directory = ROOT/'_artifacts/personal'/f'validation-{time.time_ns()}'
    directory.mkdir(parents=True)
    result = dict(status='RUNNING',source_sha256=digest,commit=commit,directory=str(directory),steps=[])
    report = directory/'report.json'
    def save(): report.write_text(json.dumps(result,indent=2)+'\n')
    def run(name, arguments):
        require(source_hash()==digest,'source changed before '+name)
        row = dict(name=name,command=arguments,status='RUNNING',log=str(directory/(name+'.log')))
        result['steps'].append(row);save();print(name+': started',flush=True)
        start=time.monotonic()
        with Path(row['log']).open('wb') as log:
            p=subprocess.Popen(arguments,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                p.wait()
            except BaseException:
                stop_process(p)
                raise
        row.update(status='PASS' if p.returncode==0 else 'FAIL',exit=p.returncode,seconds=time.monotonic()-start)
        save();require(p.returncode==0,('validation failed',name,row['log']))
        require(source_hash()==digest,'source changed during '+name)
        print(name+': PASS',flush=True)
    py=sys.executable
    try:
        for name, command in [
            ('compiler',[py,'tools/evidence.py','validate','5.5.0']),
            ('instrumentation',[py,'tools/fuzz-smoke.py']),
            ('interop',[py,'tools/interop.py']),
            ('streaming-bounds',[py,'tools/performance.py']),
            ('coverage',[py,'tools/coverage.py']),
            ('mutations',[py,'tools/mutations.py']),
            ('historical-timeout-replay',[py,'tools/triage_timeout.py']),
            ('eio-smoke',[py,'tools/personal_use.py','--mode','smoke']),
            ('eio-profile',[py,'tools/personal_use.py','--mode','profile','--seconds','10']),
        ]: run(name,command)
        if args.long:
            # The profile above runs alone. Soak timing is not used for performance
            # ranking, so it can share this frozen candidate with one AFL worker.
            jobs=[]
            try:
                for name, command in [
                    ('campaigns',[py,'tools/campaign.py','--seconds','1800']),
                    ('eio-soak',[py,'tools/personal_use.py','--mode','soak','--seconds','7200',
                                 '--binary',str(ROOT/'_build-pkg-5.5.0/default/examples/personal/eio_server.exe')]),
                ]:
                    log=directory/(name+'.log');handle=log.open('wb')
                    p=subprocess.Popen(command,cwd=ROOT,stdout=handle,stderr=subprocess.STDOUT,start_new_session=True)
                    row=dict(name=name,command=command,status='RUNNING',log=str(log),pid=p.pid)
                    result['steps'].append(row);jobs.append((p,handle,row,time.monotonic()))
                    save();print(name+': started',flush=True)
                while jobs:
                    require(source_hash()==digest,'source changed during long runs')
                    for job in list(jobs):
                        p,handle,row,start=job
                        if p.poll() is not None:
                            handle.close();jobs.remove(job)
                            row.update(status='PASS' if p.returncode==0 else 'FAIL',exit=p.returncode,seconds=time.monotonic()-start)
                            save();require(p.returncode==0,('long run failed',row['name'],row['log']))
                            print(row['name']+': PASS',flush=True)
                    if jobs: time.sleep(5)
            finally:
                for p,handle,row,start in jobs:
                    stop_process(p)
                    handle.close();row['status']='INTERRUPTED'
        result['status']='EXPERIMENTS_PASSED'
        result['readiness']='NOT_READY'
        result['unresolved_findings']=['Historical request timeout: repeated replays are not a root-cause classification.']
        save();print(json.dumps(dict(status=result['status'],readiness=result['readiness'],report=str(report))),flush=True)
    except BaseException as exn:
        result['status']='FAIL';result['error']=repr(exn);save();raise


if __name__=='__main__': main()
