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
