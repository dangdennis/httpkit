#!/usr/bin/env python3
"""Advisory timing plus executable queue bounds and mixed native socket loads."""
from checks import require
import concurrent.futures
import http.client
import json
import os
import random
import statistics
import subprocess
import threading
import time
from evidence import source_hash, record
from dune_env import ROOT, configuration, command
from interop import backend, expected

dune,env,_=configuration();version=env['HARNESS_COMPILER'];digest=source_hash()
subprocess.run(command(dune,env,['build','bench/stream_bench.exe','test/interop/eio_server.exe','test/interop/lwt_server.exe']),cwd=ROOT,env=env,check=True,timeout=1800)
binary=ROOT/f'_build-pkg-{version}/default/bench/stream_bench.exe'
samples=[json.loads(subprocess.check_output([str(binary)],text=True,timeout=30)) for _ in range(5)]
for sample in samples:
    require(sample['compiler']==version and sample['profile']=='uninstrumented', "performance.py: sample['compiler']==version and sample['profile']=='uninstrumented'")
    require([r['body_bytes'] for r in sample['results']]==[65536,1048576,16777216], "performance.py: [r['body_bytes'] for r in sample['results']]==[65536,1048576,16777216]")
    require(all(0<r['peak_engine_output_bytes']<=32768 and r['allocated_bytes']>=0 and r['ns']>0 for r in sample['results']), "performance.py: all(0<r['peak_engine_output_bytes']<=32768 and r['allocated_bytes']>=0 and r['ns']>0 for r in sample['results'])")
# This is a same-source noise measurement, not a before/after regression verdict.
noise=[]
for index in range(3):
    values=[sample['results'][index]['ns'] for sample in samples]
    noise.append({'body_bytes':samples[0]['results'][index]['body_bytes'],'median_ns':statistics.median(values),
                  'coefficient_of_variation':statistics.stdev(values)/statistics.mean(values)})
loads=[]
for runtime in ['eio','lwt']:
    with backend(runtime,details=True) as (port,pid):
        rss=[];stop=threading.Event()
        def sample_rss():
            while not stop.is_set():
                try:rss.append(int(subprocess.check_output(['ps','-o','rss=','-p',str(pid)],text=True,timeout=2).strip()))
                except (ValueError,subprocess.SubprocessError):pass
                stop.wait(.02)
        sampler=threading.Thread(target=sample_rss);sampler.start()
        def worker(seed):
            rng=random.Random(seed);latencies=[];total=0
            conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
            try:
                for _ in range(50):
                    size=rng.choice([0,17,4096,262144]);body=b'a'*size
                    chunked=bool(rng.getrandbits(1));path='/chunked' if chunked else '/fixed'
                    chunks=(body[i:i+8192] for i in range(0,len(body),8192)) if chunked else body
                    start=time.perf_counter_ns();conn.request('POST',path,body=chunks,encode_chunked=chunked)
                    response=conn.getresponse();payload=response.read()
                    require(response.status==200 and payload==expected('POST',path,body), "performance.py: response.status==200 and payload==expected('POST',path,body)")
                    latencies.append(time.perf_counter_ns()-start);total+=size
            finally:conn.close()
            return latencies,total
        started=time.monotonic()
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:outputs=list(pool.map(worker,[42,43,44,45]))
        finally:stop.set();sampler.join(timeout=3)
        elapsed=time.monotonic()-started;values=sorted(n for ns,_ in outputs for n in ns)
        require(len(values)==200 and rss, 'missing workload or RSS observations')
        loads.append({'runtime':runtime,'requests':len(values),'concurrency':4,'body_bytes':sum(n for _,n in outputs),
                      'elapsed_seconds':elapsed,'p50_ns':statistics.median(values),'p99_ns':values[int(len(values)*.99)-1],
                      'peak_process_rss_kib':max(rss),'rss_samples':len(rss)})
require(source_hash()==digest, 'sources changed during performance evidence')
record('performance-'+version+'.json',{'status':'PASS','compiler':version,'hard_queue_bound':32768,'sessions':samples,
    'noise':noise,'mixed_loads':loads,'timing_verdict':'ADVISORY','stable_runner_gate':'NOT_READY',
    'limitations':['Same-source local samples, not a paired baseline on reserved hardware.',
                   'RSS includes runtime, GC and OS effects; queue payload counts are not RSS bounds.',
                   '200 mixed requests per adapter are a smoke workload, not the release soak.']})
print(json.dumps({'status':'PASS','hard_queue_bound':32768,'timing_verdict':'ADVISORY','mixed_loads':loads},indent=2))
