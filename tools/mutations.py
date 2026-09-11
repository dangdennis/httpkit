#!/usr/bin/env python3
"""Curated source mutants must compile, then fail a real production test suite."""

from checks import require
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from dune_env import ROOT, configuration, command
from evidence import record, source_hash

dune, env, _ = configuration()
version = env["HARNESS_COMPILER"]
digest = source_hash()
compiler = Path(
    subprocess.check_output(
        command(dune, env, ["exec", "--", "sh", "-c", "command -v ocamlc"]),
        cwd=ROOT,
        env=env,
        text=True,
    ).strip()
).resolve()
clean = {k: v for k, v in env.items() if not k.startswith(("OCAML", "CAML", "DUNE"))}
clean["PATH"] = str(compiler.parent) + os.pathsep + clean["PATH"]
# Include direct test dependencies even if another platform happens to pull
# them in transitively (e.g. base64 through the macOS Eio dependency closure).
selected = subprocess.check_output(
    command(
        dune,
        env,
        [
            "exec",
            "--",
            "ocamlfind",
            "query",
            "-recursive",
            "-format",
            "%d",
            "alcotest",
            "qcheck-core",
            "yojson",
            "base64",
            "mtime.clock.os",
            "eio_main",
            "lwt.unix",
            "crowbar",
            "ipaddr",
        ],
    ),
    cwd=ROOT,
    env=env,
    text=True,
).splitlines()
roots = {
    next(
        parent
        for parent in [Path(p), *Path(p).parents]
        if parent.name == "lib" and parent.parent.name == "target"
    )
    for p in selected
}
clean["OCAMLPATH"] = os.pathsep.join(str(p) for p in sorted(roots))
out = ROOT / "_artifacts/mutations"
out.mkdir(parents=True, exist_ok=True)
mutants = [
    (
        "framing-cl-te",
        "lib/http1/http_kit_http1.ml",
        "if cl <> [] && te <> [] then Error Ambiguous_framing",
        "if false && cl <> [] && te <> [] then Error Ambiguous_framing",
        "test/http1/http1_test.exe",
    ),
    (
        "foreign-request-id",
        "lib/engine/http_kit_engine.ml",
        "a.owner == b.owner && a.number = b.number",
        "a.owner == a.owner && a.number = b.number",
        "test/engine/engine_test.exe",
    ),
    (
        "output-accounting",
        "lib/engine/http_kit_engine.ml",
        "t.queued <- t.queued - count;",
        "t.queued <- t.queued - min count 0;",
        "test/engine/engine_test.exe",
    ),
]
results = []
with tempfile.TemporaryDirectory(prefix="http-kit-mutants-") as directory:
    stage = Path(directory)
    for name in ["lib", "test", "fuzz", "examples", "bench"]:
        shutil.copytree(ROOT / name, stage / name)
    for path in ROOT.glob("*.opam"):
        shutil.copy2(path, stage / path.name)
    shutil.copy2(ROOT / "dune-project", stage / "dune-project")
    (stage / "dune-workspace").write_text("(lang dune 3.24)\n(pkg disabled)\n")

    def build(target):
        p = subprocess.run(
            [dune, "build", target],
            cwd=stage,
            env=clean,
            capture_output=True,
            timeout=180,
        )
        if p.returncode:
            raise RuntimeError(
                "mutant compilation is not a test kill:\n" + p.stderr.decode()
            )

    def execute(target):
        return subprocess.run(
            [str(stage / "_build/default" / target)],
            cwd=stage,
            env=clean,
            capture_output=True,
            timeout=60,
        )

    for target in sorted({entry[-1] for entry in mutants}):
        build(target)
        baseline = execute(target)
        require(baseline.returncode == 0, baseline.stdout + baseline.stderr)
    for name, file, before, after, target in mutants:
        path = stage / file
        original = path.read_text()
        require(original.count(before) == 1, ("mutant site drift", name))
        try:
            path.write_text(original.replace(before, after))
            build(target)
            result = execute(target)
            (out / (name + ".log")).write_bytes(result.stdout + result.stderr)
            require(
                result.returncode != 0 and b"FAIL" in result.stdout + result.stderr,
                ("surviving mutant", name),
            )
            results.append(
                {"name": name, "status": "KILLED", "compiled": True, "suite": target}
            )
        finally:
            path.write_text(original)
require(source_hash() == digest, "sources changed during mutation validation")
record(
    "mutations-" + version + ".json",
    {
        "status": "PASS",
        "compiler": version,
        "results": results,
        "scope": "Three curated first-party framing, ownership and output-accounting mutations; not an exhaustive mutation score.",
    },
)
print(json.dumps({"status": "PASS", "mutants": results}, indent=2))
