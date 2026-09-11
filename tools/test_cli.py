#!/usr/bin/env python3
"""Exercise actual exit status, replay, shrinking, reports, and incomplete suites."""
from checks import require
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
    require(p.returncode == code, (args, p.returncode, p.stdout, p.stderr))
    return json.loads(p.stdout)

with tempfile.TemporaryDirectory(prefix='http-kit-cli-') as tmp:
    tmp = Path(tmp)
    fixture = tmp / 'fault.json'
    run('example', 'drop-write', fixture)
    failed = run('replay', fixture, '--subject', 'drop-write', code=1)
    require(failed['result']['failure']['rule'] == 'OUTPUT.EXACT', "test_cli.py: failed['result']['failure']['rule'] == 'OUTPUT.EXACT'")
    compiler = os.environ.get('HARNESS_COMPILER', '5.5.0')
    require(failed['provenance']['compiler'] == compiler, "test_cli.py: failed['provenance']['compiler'] == compiler")
    packages = json.loads(failed['provenance']['packages'])
    require(packages['lock_directory'] == 'dune.lock', "test_cli.py: packages['lock_directory'] == 'dune.lock'")
    require('yojson.3.0.0.pkg' in packages['packages'], "test_cli.py: 'yojson.3.0.0.pkg' in packages['packages']")
    run('replay', fixture)  # Same case with the correct subject is positive control.
    original = fixture.read_bytes()
    run('shrink', fixture, '--subject', 'drop-write', '--output', fixture, code=2)
    require(fixture.read_bytes() == original, 'test_cli.py: fixture.read_bytes() == original')
    run('shrink', fixture, '--subject', 'drop-write', '--output', tmp / 'small.json')
    run('replay', tmp / 'small.json', '--subject', 'drop-write', code=1)
    run('run', '--suite', 'missing', code=3)
    run('run', '--tier', 'nightly', code=3)
    run('run', '--count', code=2)
    release = run('readiness', '--release', code=3)
    require(release['status'] == 'NOT_READY', "test_cli.py: release['status'] == 'NOT_READY'")
    require(release['gates'] and any(g['status'] == 'NOT_READY' for g in release['gates']), "test_cli.py: release['gates'] and any(g['status'] == 'NOT_READY' for g in release['gates'])")
    require(run('readiness', '--milestone', 'M7', code=3) == release, "test_cli.py: run('readiness', '--milestone', 'M7', code=3) == release")
    direct = subprocess.run(['python3', str(ROOT / 'tools/release.py')], cwd=ROOT,
                            capture_output=True, text=True, timeout=30)
    require(direct.returncode == 3 and json.loads(direct.stdout) == release, 'test_cli.py: direct.returncode == 3 and json.loads(direct.stdout) == release')
    fixture.write_text('{bad')
    run('replay', fixture, code=2)
    report = run('run', '--suite', 'property', '--count', '5', '--report', tmp / 'report.json',
                 '--junit', tmp / 'report.xml')
    require(report['executed'] == 4, "test_cli.py: report['executed'] == 4")
    require(json.loads((tmp / 'report.json').read_text()) == report, "test_cli.py: json.loads((tmp / 'report.json').read_text()) == report")
    require(ET.parse(tmp / 'report.xml').getroot().attrib['tests'] == '4', "test_cli.py: ET.parse(tmp / 'report.xml').getroot().attrib['tests'] == '4'")
    core = run('run', '--suite', 'core', '--count', '5')
    require(core['executed'] == 18 and core['scope'] == 'M2 core values', "test_cli.py: core['executed'] == 18 and core['scope'] == 'M2 core values'")
print('PASS: CLI exit codes, fresh replay, shrinking, JSON/JUnit, missing suites, and release status')
