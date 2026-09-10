#!/usr/bin/env python3
"""Exercise actual exit status, replay, shrinking, reports, and incomplete suites."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent

def run(*args, code=0):
    p = subprocess.run([str(ROOT / 'tools/harness'), *map(str, args)], cwd=ROOT,
                       capture_output=True, text=True, timeout=30)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return json.loads(p.stdout)

with tempfile.TemporaryDirectory(prefix='http-kit-cli-') as tmp:
    tmp = Path(tmp)
    fixture = tmp / 'fault.json'
    run('example', 'drop-write', fixture)
    failed = run('replay', fixture, '--subject', 'drop-write', code=1)
    assert failed['result']['failure']['rule'] == 'OUTPUT.EXACT'
    compiler = os.environ.get('HARNESS_COMPILER', '5.5.0')
    assert failed['provenance']['compiler'] == compiler
    packages = json.loads(failed['provenance']['packages'])
    assert packages['lock_directory'] == ('dune.lock' if compiler == '5.5.0' else 'dune.5.2.lock')
    assert 'yojson.3.0.0.pkg' in packages['packages']
    run('replay', fixture)  # Same case with the correct subject is positive control.
    original = fixture.read_bytes()
    run('shrink', fixture, '--subject', 'drop-write', '--output', fixture, code=2)
    assert fixture.read_bytes() == original
    run('shrink', fixture, '--subject', 'drop-write', '--output', tmp / 'small.json')
    run('replay', tmp / 'small.json', '--subject', 'drop-write', code=1)
    run('run', '--suite', 'missing', code=3)
    run('run', '--tier', 'nightly', code=3)
    run('run', '--count', code=2)
    release = run('readiness', '--release', code=3)
    assert release['registry']['pending_release_capabilities']
    fixture.write_text('{bad')
    run('replay', fixture, code=2)
    report = run('run', '--suite', 'property', '--count', '5', '--report', tmp / 'report.json',
                 '--junit', tmp / 'report.xml')
    assert report['executed'] == 4
    assert json.loads((tmp / 'report.json').read_text()) == report
    assert ET.parse(tmp / 'report.xml').getroot().attrib['tests'] == '4'
print('PASS: CLI exit codes, fresh replay, shrinking, JSON/JUnit, missing suites, and release status')
