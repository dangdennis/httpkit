#!/usr/bin/env python3
"""Measure execution points in the six extension packages, excluding aliases/configuration."""

import json
from pathlib import Path
import re
import subprocess
import time
from dune_env import ROOT, configuration
from evidence import source_hash
from checks import require


def main():
    dune, env, _ = configuration()
    digest = source_hash()
    directory = ROOT / "_artifacts/framework" / f"extensions-coverage-{time.time_ns()}"
    directory.mkdir(parents=True)
    env["BISECT_FILE"] = str(directory / "point")
    flags = ["--workspace=" + str(ROOT / "dune-workspace.coverage"), "--build-dir=_build-coverage"]

    def run(args):
        return subprocess.check_output([dune, args[0], *flags, *args[1:]],
                                       cwd=ROOT, env=env, text=True,
                                       stderr=subprocess.STDOUT, timeout=1800)

    (directory / "tests.log").write_text(run(["runtest", "--instrument-with", "bisect_ppx",
                                            "--force", "test/extensions"]))
    summary = run(["exec", "--", "bisect-ppx-report", "summary",
                   "--coverage-path=" + str(directory), "--per-file"])
    (directory / "summary.txt").write_text(summary)
    prefixes = ["lib/" + name + "/" for name in
                ["cookie", "password", "session_eio", "oidc", "oidc_eio", "web_lwt"]]
    rows = []
    for line in summary.splitlines():
        match = re.match(r"\s*[\d.]+\s*%\s+(\d+)/(\d+)\s+(lib/\S+\.ml)", line)
        if match and int(match[2]) > 0 and any(match[3].startswith(prefix) for prefix in prefixes):
            rows.append(dict(file=match[3], covered=int(match[1]), total=int(match[2])))
    expected = {str(p.relative_to(ROOT)) for prefix in prefixes for p in (ROOT / prefix).glob("*.ml")}
    expected.remove("lib/web_lwt/httpkit_lwt.ml")
    require({r["file"] for r in rows} == expected, ("coverage inventory mismatch", rows, expected))
    covered = sum(r["covered"] for r in rows)
    total = sum(r["total"] for r in rows)
    require(total > 0 and source_hash() == digest, "missing points or changed sources")
    report = dict(status="PASS", source_sha256=digest, covered=covered, total=total,
                  percent=100 * covered / total, files=rows, directory=str(directory),
                  exclusions=["module aliases", "build configuration", "native linkage shim", "upstream dependencies"])
    (ROOT / "_artifacts/framework/extensions-coverage.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS extension coverage: {covered}/{total} instrumented OCaml points ({report['percent']:.2f}%)")


if __name__ == "__main__":
    main()
