#!/usr/bin/env python3
"""Fail-closed release assessment. Missing evidence is never inferred as passing."""
from checks import has_inventory, MUTANTS, INTEROP_LANES
import argparse
import json
from pathlib import Path
import subprocess
from evidence import ROOT, OUT, source_hash

def assess(directory, expected, policy, target_names, license_present):
    gates=[]
    def add(name,ok,reason):
        gates.append({'gate':name,'status':'PASS' if ok else 'NOT_READY','detail':reason})
    def evidence(name):
        try:
            data=json.loads((directory/(name+'.json')).read_text())
            if not isinstance(data,dict) or data.get('source_sha256')!=expected or data.get('status')!='PASS':return None
            return data
        except (OSError,ValueError):return None
    for version in ['5.5.0']:
        data=evidence('compiler-'+version)
        add('compiler/'+version,bool(data and data.get('compiler')==version and all(data.get(k) is True for k in ['core_consumer','http1_consumer','engine_consumer','adapter_consumer','middleware_consumer','router_consumer','routing_examples']) and data.get('odoc')=='3.2.1'),'Source-matched tests, docs and installed consumers.')
        data=evidence('interop-'+version)
        add('interop/'+version,bool(data and has_inventory(data.get('results'), 'lane', INTEROP_LANES)),'Six direct/Nginx smoke lanes; extended reference evidence is separate.')
    data=evidence('afl/evidence')
    add('instrumentation',bool(data and data.get('coverage_maps_differ') is True and data.get('crowbar_assertion_discovered_and_replayed') is True),'Coverage-map positive control and discovered/replayed planted failure.')
    data=evidence('mutations-5.5.0')
    add('curated-mutations',bool(data and has_inventory(data.get('results'), 'name', MUTANTS) and all(r.get('compiled') is True and r.get('status')=='KILLED' for r in data['results'])),'Compiled framing, ownership and output-accounting mutants must fail tests.')
    data=evidence('coverage')
    add('point-coverage',bool(data and data.get('compiler')=='5.5.0' and isinstance(data.get('percent'),(int,float)) and data['percent']>=policy['coverage_minimum_percent'] and data.get('missing_files')==[]),'At least 95% instrumented core/codec/engine points; this is not branch coverage.')
    for name in target_names:
        data=evidence('campaign-'+name)
        add('fuzz/'+name,bool(data and data.get('target')==name and isinstance(data.get('seconds_executed'),int) and data['seconds_executed']>=policy['fuzz_seconds_per_target'] and data.get('findings')==0 and data.get('uninstrumented_replays',0)>0),'Eight hours for this target, no untriaged findings, uninstrumented corpus replay.')
    data=evidence('platform-matrix')
    add('platform-matrix',bool(data and set(policy['required_platforms'])<=set(data.get('passed',[]))),'Successful CI evidence for all declared platform/compiler pairs.')
    for name in policy['required_reviews']:
        data=evidence(name)
        ok=bool(data and data.get('reviewer') and data.get('review_url') and data.get('approved') is True and data.get('unresolved_findings')==[])
        if name=='security-review':ok=ok and data.get('independent_of_implementation') is True
        add(name,ok,'A real reviewer must supply source-matched findings and approval; maintainer verifies identity and independence.')
    for name in policy['required_extended_evidence']:
        data=evidence(name)
        add(name,bool(data and data.get('evidence_paths') and data.get('approved_by') and data.get('unresolved_findings')==[]),'Reviewed source-matched evidence required; smoke results do not substitute for this gate.')
    add('license',license_present,'Publication license must be chosen and committed by the owner.')
    data=evidence('private-reporting')
    add('private-reporting',bool(data and data.get('verified_channel') and data.get('verified_by')),'Verify the private vulnerability channel before a public release.')
    return {'schema_version':1,'status':'READY' if all(g['status']=='PASS' for g in gates) else 'NOT_READY',
            'source_sha256':expected,'gates':gates}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path);args=parser.parse_args()
    policy=json.loads((ROOT/'toolchain/release-policy.json').read_text())
    names=[x['name'] for x in json.loads((ROOT/'toolchain/fuzz-targets.json').read_text())]
    report=assess(OUT,source_hash(),policy,names,(ROOT/'LICENSE').is_file())
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    return 0 if report['status']=='READY' else 3
if __name__=='__main__':raise SystemExit(main())
