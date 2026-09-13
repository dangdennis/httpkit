#!/usr/bin/env python3
"""Positive and negative controls for personal-use resource acceptance."""
from copy import deepcopy
from personal_use import check_resources
from checks import require

base = dict(active=1,unexpected_errors=0,descriptors=6,live_words=16000,rss_kib=16000)
rows = [dict(base) for _ in range(12)]
check_resources(rows)

def reject(changed):
    try:
        check_resources(changed)
    except RuntimeError:
        return
    raise RuntimeError('faulty resource observations accepted')

reject([])
for field, value in [('active',2),('unexpected_errors',1),('descriptors',12),
                     ('live_words',200000),('rss_kib',300000)]:
    changed=deepcopy(rows);changed[-1][field]=value;reject(changed)
changed=deepcopy(rows)
for row in changed[-3:]:row['rss_kib']=60000
reject(changed)
print('PASS: resource controls reject leaks, unexpected errors, missing observations and RSS growth')

# Exercise the coordinator with fake child processes: --skip-afl must prevent
# every AFL launch even with --long, while retaining the 7200-second Eio soak.
import contextlib
import io
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
import personal_validation

launched = []
class FinishedProcess:
    returncode = 0
    pid = 999999
    def __init__(self, arguments, **kwargs):
        launched.append(arguments)
    def wait(self, **kwargs): return 0
    def poll(self): return 0

with tempfile.TemporaryDirectory() as directory:
    with patch.object(personal_validation, 'ROOT', Path(directory)), \
         patch.object(personal_validation, 'source_hash', return_value='candidate'), \
         patch.object(personal_validation.subprocess, 'check_output', return_value='commit\n'), \
         patch.object(personal_validation.subprocess, 'Popen', FinishedProcess), \
         patch.object(personal_validation.sys, 'argv', ['personal_validation.py','--long','--skip-afl']), \
         contextlib.redirect_stdout(io.StringIO()):
        personal_validation.main()
    require(len(launched) == 8, ('missing non-AFL checks', launched))
    require(not any(any('fuzz-smoke.py' in arg or 'triage_timeout.py' in arg or 'campaign.py' in arg
                        for arg in args) for args in launched), 'skip-AFL launched an AFL command')
    require(any('--mode' in args and 'soak' in args and '7200' in args for args in launched), 'missing full soak')
    report = json.loads(next(Path(directory).glob('_artifacts/personal/validation-*/report.json')).read_text())
    require(report['afl']=='DEFERRED_BY_REQUEST' and report['public_release']=='NOT_READY'
            and report['unresolved_findings'], 'deferred findings or public release limits lost')
print('PASS: --long --skip-afl runs every non-AFL check and full soak without launching AFL')
