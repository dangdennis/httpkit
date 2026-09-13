#!/usr/bin/env python3
"""Run source-frozen framework acceptance, excluding all AFL work."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

from checks import require
from evidence import ROOT, source_hash
from personal_validation import progress, stop_process


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--long",
        action="store_true",
        help="include 30-minute SQLite and two-hour PostgreSQL runs",
    )
    args = parser.parse_args()
    digest = source_hash()
    directory = ROOT / "_artifacts/framework" / f"validation-{time.time_ns()}"
    directory.mkdir(parents=True)
    report = dict(
        status="RUNNING",
        source_sha256=digest,
        directory=str(directory),
        afl="DEFERRED_BY_REQUEST",
        steps=[],
    )

    def save():
        (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(name, arguments):
        require(source_hash() == digest, "source changed before " + name)
        row = dict(
            name=name,
            command=arguments,
            status="RUNNING",
            log=str(directory / (name + ".log")),
        )
        report["steps"].append(row)
        save()
        progress(name + ": started")
        started = time.monotonic()
        with Path(row["log"]).open("wb") as log:
            process = subprocess.Popen(
                arguments,
                cwd=ROOT,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            row["pid"] = process.pid
            save()
            try:
                process.wait()
            except BaseException:
                stop_process(process)
                row["status"] = "INTERRUPTED"
                save()
                raise
        row.update(
            status="PASS" if process.returncode == 0 else "FAIL",
            exit=process.returncode,
            seconds=time.monotonic() - started,
        )
        save()
        require(process.returncode == 0, ("validation failed", name, row["log"]))
        require(source_hash() == digest, "source changed during " + name)
        progress(name + ": PASS")

    py = sys.executable
    try:
        for name, arguments in [
            ("compiler", [py, "tools/evidence.py", "validate", "5.5.0"]),
            ("runner-cleanup", [py, "tools/test_framework_runners.py"]),
            ("databases", [py, "tools/test_framework_databases.py"]),
            ("framework-coverage", [py, "tools/framework_coverage.py"]),
            ("framework-mutations", [py, "tools/framework_mutations.py"]),
            ("interop", [py, "tools/interop.py"]),
            ("streaming-bounds", [py, "tools/performance.py"]),
            ("coverage", [py, "tools/coverage.py"]),
            ("mutations", [py, "tools/mutations.py"]),
            (
                "sqlite-smoke",
                [
                    py,
                    "tools/framework_load.py",
                    "--mode",
                    "smoke",
                    "--database",
                    "sqlite",
                ],
            ),
            (
                "postgresql-smoke",
                [
                    py,
                    "tools/framework_load.py",
                    "--mode",
                    "smoke",
                    "--database",
                    "postgresql",
                ],
            ),
            (
                "profile",
                [
                    py,
                    "tools/framework_load.py",
                    "--mode",
                    "profile",
                    "--database",
                    "sqlite",
                ],
            ),
        ]:
            run(name, arguments)
        if args.long:
            for mode, database in [("canary", "sqlite"), ("soak", "postgresql")]:
                run(
                    mode,
                    [
                        py,
                        "tools/framework_load.py",
                        "--mode",
                        mode,
                        "--database",
                        database,
                    ],
                )
        report["status"] = "PASS"
        report["sustained_acceptance"] = "PASS" if args.long else "NOT_RUN"
        report["limitations"] = [
            "Two historical AFL timeout findings remain unresolved.",
            "Hosted CI and independent review remain separate gates.",
        ]
        save()
        progress(json.dumps(dict(status="PASS", report=str(directory / "report.json"))))
    except BaseException as error:
        report["status"] = (
            "INTERRUPTED" if isinstance(error, KeyboardInterrupt) else "FAIL"
        )
        report["error"] = repr(error)
        save()
        raise


if __name__ == "__main__":
    main()
