#!/usr/bin/env python3
"""Curated framework defects must compile and fail executable controls."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from checks import require
from dune_env import ROOT, configuration, command
from evidence import source_hash


def main():
    dune, env, _ = configuration()
    digest = source_hash()

    def locked(args):
        return subprocess.check_output(
            command(dune, env, args), cwd=ROOT, env=env, text=True, timeout=300
        ).strip()

    compiler = Path(locked(["exec", "--", "sh", "-c", "command -v ocamlc"])).resolve()
    selected = locked(
        [
            "exec",
            "--",
            "ocamlfind",
            "query",
            "-recursive",
            "-format",
            "%d",
            "eio_main",
            "ipaddr",
            "digestif",
            "eqaf",
            "base64",
            "yojson",
            "qcheck-core",
            "mtime.clock.os",
        ]
    ).splitlines()
    roots = {
        next(
            parent
            for parent in [Path(p), *Path(p).parents]
            if parent.name == "lib" and parent.parent.name == "target"
        )
        for p in selected
    }
    clean = {
        k: v for k, v in env.items() if not k.startswith(("OCAML", "CAML", "DUNE"))
    }
    clean.update(
        PATH=str(compiler.parent) + os.pathsep + clean["PATH"],
        OCAMLPATH=os.pathsep.join(map(str, roots)),
    )
    directory = ROOT / "_artifacts/framework" / f"mutations-{time.time_ns()}"
    directory.mkdir(parents=True)
    mutants = [
        (
            "cookie-secure-default",
            "lib/web/cookie.ml",
            "?(secure = true)",
            "?(secure = false)",
            "test/web/web_test.exe",
        ),
        (
            "multipart-quota",
            "lib/web/multipart.ml",
            "if n > t.max_part - t.part_bytes then",
            "if false && n > t.max_part - t.part_bytes then",
            "test/web/web_test.exe",
        ),
        (
            "session-expiry",
            "lib/web/session.ml",
            "s.expires <= now",
            "false && s.expires <= now",
            "test/web/web_test.exe",
        ),
        (
            "request-lifetime",
            "lib/web_eio/app.ml",
            "if not !alive then",
            "if false && not !alive then",
            "test/web_eio/runtime_test.exe",
        ),
    ]
    results = []
    with tempfile.TemporaryDirectory(prefix="httpkit-framework-mutants-") as temporary:
        stage = Path(temporary)
        for package in [
            "core",
            "http1",
            "engine",
            "eio",
            "router",
            "middleware",
            "web",
            "web_eio",
        ]:
            shutil.copytree(ROOT / "lib" / package, stage / "lib" / package)
        for suite in ["web", "web_eio"]:
            shutil.copytree(ROOT / "test" / suite, stage / "test" / suite)
        for p in ROOT.glob("*.opam"):
            shutil.copy2(p, stage / p.name)
        (stage / "dune-project").write_text(
            "(lang dune 3.24)\n(name framework-mutants)\n"
        )
        (stage / "dune-workspace").write_text("(lang dune 3.24)\n(pkg disabled)\n")

        def build(target):
            result = subprocess.run(
                [dune, "build", target],
                cwd=stage,
                env=clean,
                capture_output=True,
                text=True,
                timeout=180,
            )
            require(
                result.returncode == 0, ("compilation is not a kill", result.stderr)
            )

        def execute(target):
            return subprocess.run(
                [str(stage / "_build/default" / target)],
                cwd=stage,
                env=clean,
                capture_output=True,
                text=True,
                timeout=30,
            )

        for target in {m[-1] for m in mutants}:
            build(target)
            result = execute(target)
            require(result.returncode == 0, ("baseline", result.stdout, result.stderr))
        for name, file, before, after, target in mutants:
            path = stage / file
            original = path.read_text()
            require(original.count(before) == 1, ("mutation site drift", name))
            try:
                path.write_text(original.replace(before, after))
                build(target)
                result = execute(target)
                (directory / (name + ".log")).write_text(result.stdout + result.stderr)
                require(
                    result.returncode > 0 and "Fatal error" in result.stderr,
                    ("survived or infrastructure failure", name, result.stderr),
                )
                results.append(dict(name=name, status="KILLED", compiled=True))
            finally:
                path.write_text(original)
    require(source_hash() == digest, "mutations source changed")
    report = dict(
        status="PASS",
        source_sha256=digest,
        results=results,
        scope="Four curated controls, not an exhaustive mutation score",
    )
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (ROOT / "_artifacts/framework/mutations.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print("PASS four compiled framework mutants killed by tests")


if __name__ == "__main__":
    main()
