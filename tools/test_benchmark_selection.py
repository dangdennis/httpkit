"""Exercise listing and whole-group selection without timing measurements."""

import json
import subprocess
from dune_env import ROOT, configuration, command
from checks import require

dune, env, _ = configuration()
subprocess.run(
    command(dune, env, ["build", "bench/suite_bench.exe"]),
    cwd=ROOT,
    env=env,
    check=True,
    timeout=1800,
)
binary = (
    ROOT / ("_build-pkg-" + env["HARNESS_COMPILER"]) / "default/bench/suite_bench.exe"
)


def catalog(*args, success=True):
    result = subprocess.run(
        [str(binary), "--external", *args],
        env=env,
        text=True,
        capture_output=True,
        timeout=60,
    )
    require((result.returncode == 0) == success, result.stderr)
    return json.loads(result.stdout) if success else result.stderr


selection = ["--family", "exchange", "--case", "writer/fixed/bytes-0/messages-8"]
listed = catalog(*selection, "--list")
prepared = catalog(*selection, "--preflight-only")
require(listed == prepared, "exchange catalog changed during preflight")
require(
    len(listed["results"]) == 3, "selection did not retain exactly one comparison group"
)
require(
    "complete comparison groups"
    in catalog("--family", "exchange", "--case", "/http-kit", "--list", success=False),
    "partial group selection was not rejected",
)
body = catalog(
    "--family",
    "body",
    "--case",
    "request/fixed/bytes-4096/step-16384/immediate/owned-scan",
    "--list",
)
require(len(body["results"]) == 3, "body selection did not isolate its group")
require(
    body
    == catalog(
        "--family",
        "body",
        "--case",
        "request/fixed/bytes-4096/step-16384/immediate/owned-scan",
        "--preflight-only",
    ),
    "compatible body selection changed in preflight",
)
print("PASS: listing, selected body/exchange preflight, and incomplete group rejection")
