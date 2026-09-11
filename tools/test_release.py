#!/usr/bin/env python3
"""The release gate must reject missing, stale, shallow and contradictory evidence."""
from checks import require, MUTANTS, INTEROP_LANES
import json
from pathlib import Path
import tempfile
from release import assess
policy={'fuzz_seconds_per_target':28800,'coverage_minimum_percent':95,
 'required_platforms':['linux-x86_64/5.5.0'],'required_reviews':['security-review'],
 'required_extended_evidence':['soak']}
with tempfile.TemporaryDirectory() as directory:
    root=Path(directory)
    def check():return assess(root,'current',policy,['core'],True)
    def put(name,**fields):
        p=root/(name+'.json');p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text(json.dumps(dict(status='PASS',source_sha256='current',**fields)))
    require(check()['status']=='NOT_READY', "test_release.py: check()['status']=='NOT_READY'")
    for version in ['5.5.0']:
        put('compiler-'+version,compiler=version,core_consumer=True,http1_consumer=True,engine_consumer=True,adapter_consumer=True,middleware_consumer=True,router_consumer=True,routing_examples=True,odoc='3.2.1')
        put('interop-'+version,results=[{'lane': lane} for lane in sorted(INTEROP_LANES)])
    put('afl/evidence',coverage_maps_differ=True,crowbar_assertion_discovered_and_replayed=True)
    put('mutations-5.5.0',results=[{'name': name, 'compiled':True,'status':'KILLED'} for name in sorted(MUTANTS)])
    put('coverage',compiler='5.5.0',percent=95,missing_files=[])
    put('campaign-core',target='core',seconds_executed=28800,findings=0,uninstrumented_replays=1)
    put('platform-matrix',passed=['linux-x86_64/5.5.0'])
    put('security-review',reviewer='test-fixture',review_url='test-fixture',approved=True,unresolved_findings=[],independent_of_implementation=True)
    put('soak',evidence_paths=['test-fixture'],approved_by='test-fixture',unresolved_findings=[])
    put('private-reporting',verified_channel='test-fixture',verified_by='test-fixture')
    require(check()['status']=='READY', 'positive control rejected')
    for name,fields in [
      ('campaign-core',dict(target='core',seconds_executed=30,findings=0,uninstrumented_replays=1)),
      ('coverage',dict(compiler='5.5.0',percent=94.9,missing_files=[])),
      ('coverage',dict(compiler='5.2.1',percent=99,missing_files=[])),
      ('security-review',dict(reviewer='test-fixture',approved=True,unresolved_findings=['open finding'])),
      ('mutations-5.5.0',dict(results=[{'compiled':False,'status':'KILLED'}]*3)),
      ('compiler-5.5.0',dict(compiler='5.2.1'))]:
        path=root/(name+'.json');original=path.read_bytes();put(name,**fields)
        require(check()['status']=='NOT_READY', name);path.write_bytes(original)
    path=root/'coverage.json';data=json.loads(path.read_text());data['source_sha256']='old';path.write_text(json.dumps(data))
    require(check()['status']=='NOT_READY', "test_release.py: check()['status']=='NOT_READY'")
    path.write_text('{broken');require(check()['status']=='NOT_READY', "test_release.py: check()['status']=='NOT_READY'")
print('PASS: release gate positive control and missing, stale, shallow, failed-compilation, wrong-compiler and unresolved-finding rejection')
