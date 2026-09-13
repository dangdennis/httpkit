#!/usr/bin/env python3
"""Report framework point coverage without conflating it with security approval."""

import json
import re
import subprocess
import time
from checks import require
from dune_env import ROOT, configuration
from evidence import source_hash


def main():
    dune, env, _ = configuration()
    directory = ROOT / "_artifacts/framework" / f"coverage-{time.time_ns()}"
    directory.mkdir(parents=True)
    digest = source_hash()
    env["BISECT_FILE"] = str(directory / "point")
    flags = [
        "--workspace=" + str(ROOT / "dune-workspace.coverage"),
        "--build-dir=_build-coverage",
    ]

    def run(args):
        return subprocess.check_output(
            [dune, args[0], *flags, *args[1:]],
            cwd=ROOT,
            env=env,
            text=True,
            stderr=subprocess.STDOUT,
            timeout=1800,
        )

    (directory / "unit.log").write_text(
        run(
            [
                "runtest",
                "--instrument-with",
                "bisect_ppx",
                "--force",
                "test/web",
                "test/web_eio",
                "test/db_eio",
            ]
        )
    )
    run(["build", "--instrument-with", "bisect_ppx", "examples/framework/server.exe"])
    with (directory / "integration.log").open("w") as log:
        subprocess.run(
            [
                "python3",
                "tools/test_framework.py",
                "--binary",
                "_build-coverage/default/examples/framework/server.exe",
            ],
            cwd=ROOT,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
            timeout=120,
        )
    with (directory / "databases.log").open("w") as log:
        subprocess.run(
            [
                "python3",
                "tools/test_framework_databases.py",
                "--binary",
                "_build-coverage/default/test/db_eio/db_test.exe",
            ],
            cwd=ROOT,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
            timeout=300,
        )
    summary = run(
        [
            "exec",
            "--",
            "bisect-ppx-report",
            "summary",
            "--coverage-path=" + str(directory),
            "--per-file",
        ]
    )
    (directory / "summary.txt").write_text(summary)
    run(
        [
            "exec",
            "--",
            "bisect-ppx-report",
            "coveralls",
            "--coverage-path=" + str(directory),
            str(directory / "lines.json"),
        ]
    )
    files = []
    for line in summary.splitlines():
        match = re.match(
            r"\s*[\d.]+\s*%\s+(\d+)/(\d+)\s+(lib/(?:web|web_eio|db_eio)/\S+\.ml)", line
        )
        if match:
            files.append(
                dict(file=match[3], visited=int(match[1]), total=int(match[2]))
            )
    aliases = {"lib/web/httpkit.ml", "lib/web_eio/httpkit_eio.ml"}
    required = {
        str(p.relative_to(ROOT))
        for layer in ["web", "web_eio", "db_eio"]
        for p in (ROOT / "lib" / layer).glob("*.ml")
    } - aliases
    missing = sorted(required - {f["file"] for f in files})
    total = sum(f["total"] for f in files)
    visited = sum(f["visited"] for f in files)
    require(
        total > 0 and not missing and digest == source_hash(),
        ("invalid or stale coverage", missing),
    )
    report = dict(
        status="MEASURED",
        source_sha256=digest,
        metric="instrumented points, not branches",
        percent=100 * visited / total,
        files=files,
        missing=missing,
        directory=str(directory),
    )
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (ROOT / "_artifacts/framework/coverage.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(summary)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
