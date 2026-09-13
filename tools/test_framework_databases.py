#!/usr/bin/env python3
"""Run PostgreSQL/SQLite acceptance in disposable local databases."""

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
from checks import require
from dune_env import ROOT, configuration, command
from evidence import source_hash


def find_postgres():
    candidates = []
    if os.environ.get("FRAMEWORK_PG_BIN"):
        candidates.append(Path(os.environ["FRAMEWORK_PG_BIN"]))
    if shutil.which("postgres"):
        candidates.append(Path(shutil.which("postgres")).resolve().parent)
    if shutil.which("pg_config"):
        probe = subprocess.run(
            ["pg_config", "--bindir"], capture_output=True, text=True, timeout=5
        )
        if probe.returncode == 0:
            candidates.append(Path(probe.stdout.strip()))
    candidates.append(Path("/Applications/Postgres.app/Contents/Versions/latest/bin"))
    for directory in candidates:
        try:
            result = subprocess.run(
                [str(directory / "postgres"), "--version"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                return directory
        except (OSError, subprocess.TimeoutExpired):
            pass
    raise RuntimeError(
        "No working PostgreSQL binaries. Set FRAMEWORK_PG_BIN to a local installation."
    )


class Postgres:
    """Own one disposable server; never address an existing database."""

    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.pg = find_postgres()
        self.data = self.directory / "data"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}

    def run(self, name, command):
        with (self.directory / (name + ".log")).open("w") as log:
            subprocess.run(
                command,
                env=self.env,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
                timeout=120,
            )

    def __enter__(self):
        self.run(
            "initdb",
            [
                str(self.pg / "initdb"),
                "-D",
                str(self.data),
                "-A",
                "trust",
                "--no-locale",
            ],
        )
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        try:
            self.run(
                "start",
                [
                    str(self.pg / "pg_ctl"),
                    "-D",
                    str(self.data),
                    "-l",
                    str(self.directory / "postgres.log"),
                    "-o",
                    f"-h 127.0.0.1 -p {port} -k ''",
                    "start",
                    "-w",
                ],
            )
        except BaseException:
            if (self.data / "postmaster.pid").exists():
                self.close()
            raise
        return f"postgresql://127.0.0.1:{port}/postgres"

    def close(self):
        self.run(
            "stop",
            [str(self.pg / "pg_ctl"), "-D", str(self.data), "stop", "-m", "fast", "-w"],
        )

    def __exit__(self, *_):
        self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary")
    args = parser.parse_args()
    if args.binary is None:
        dune, build_env, _ = configuration()
        subprocess.run(
            command(dune, build_env, ["build", "test/db_eio/db_test.exe"]),
            cwd=ROOT,
            env=build_env,
            check=True,
            timeout=1800,
        )
    binary = str(
        (
            ROOT / (args.binary or "_build-pkg-5.5.0/default/test/db_eio/db_test.exe")
        ).resolve()
    )
    directory = ROOT / "_artifacts/framework" / f"databases-{time.time_ns()}"
    directory.mkdir(parents=True)
    digest = source_hash()
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
    report = dict(status="RUNNING", source_sha256=digest, steps=[])

    def save():
        (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(name, cmd):
        with (directory / (name + ".log")).open("w") as log:
            subprocess.run(
                cmd,
                cwd=ROOT,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
                timeout=120,
            )
        report["steps"].append(name)
        save()

    try:
        run("sqlite", [binary])
        with Postgres(directory / "postgres") as uri:
            run("postgresql", [binary, uri])
        require(source_hash() == digest, "database evidence source changed")
        report["status"] = "PASS"
    except BaseException as error:
        report["status"] = "FAIL"
        report["error"] = repr(error)
        raise
    finally:
        save()
        if report["status"] == "PASS":
            (ROOT / "_artifacts/framework/databases.json").write_text(
                json.dumps(report, indent=2) + "\n"
            )
    require(report["status"] == "PASS", report)
    print("PASS PostgreSQL and SQLite; isolated PostgreSQL instance stopped")


if __name__ == "__main__":
    main()
