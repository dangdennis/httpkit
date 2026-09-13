#!/usr/bin/env python3
"""Build installed framework packages without the repository or Lwt on the path."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from checks import require
from dune_env import ROOT, configuration, command


def main():
    dune, env, _ = configuration()

    def locked(args):
        return subprocess.check_output(
            command(dune, env, args), cwd=ROOT, env=env, text=True, timeout=1800
        ).strip()

    compiler = Path(locked(["exec", "--", "sh", "-c", "command -v ocamlc"])).resolve()
    with tempfile.TemporaryDirectory(
        prefix="httpkit-framework-consumer-"
    ) as directory:
        root = Path(directory)
        clean = {
            k: v for k, v in env.items() if not k.startswith(("OCAML", "CAML", "DUNE"))
        }
        clean["PATH"] = str(compiler.parent) + os.pathsep + clean["PATH"]
        names = [
            "eio_main",
            "ipaddr",
            "yojson",
            "base64",
            "digestif",
            "eqaf",
            "mtime.clock.os",
            "caqti-eio.unix",
            "caqti-driver-postgresql",
            "caqti-driver-sqlite3",
        ]
        paths = {
            Path(p)
            for p in locked(
                [
                    "exec",
                    "--",
                    "ocamlfind",
                    "query",
                    "-recursive",
                    "-format",
                    "%d",
                    *names,
                ]
            ).splitlines()
        }
        paths = {
            p
            for p in paths
            if not any(q != p and q in p.parents for q in paths)
            and compiler.parent.parent not in p.parents
        }
        deps = root / "deps"
        deps.mkdir()
        for path in paths:
            shutil.copytree(path, deps / path.name)
            if (path.parent / "stublibs").is_dir():
                shutil.copytree(
                    path.parent / "stublibs", deps / "stublibs", dirs_exist_ok=True
                )
        require(not (deps / "lwt").exists(), "framework unexpectedly needs Lwt")
        clean["OCAMLPATH"] = str(deps)
        clean["CAML_LD_LIBRARY_PATH"] = os.pathsep.join(
            str(p.parent) for p in deps.rglob("dll*.so")
        )

        def project(path):
            path.mkdir(exist_ok=True)
            (path / "dune-project").write_text(
                "(lang dune 3.24)\n(name isolated-framework)\n"
            )
            (path / "dune-workspace").write_text("(lang dune 3.24)\n(pkg disabled)\n")

        stage = root / "source"
        project(stage)
        packages = {
            "core": "httpkit-core",
            "http1": "httpkit-http1",
            "engine": "httpkit-engine",
            "eio": "httpkit-transport-eio",
            "middleware": "httpkit-middleware",
            "router": "httpkit-router",
            "web": "httpkit",
            "web_eio": "httpkit-eio",
            "db_eio": "httpkit-db-eio",
        }
        for directory, package in packages.items():
            shutil.copytree(ROOT / "lib" / directory, stage / directory)
            shutil.copy2(ROOT / f"{package}.opam", stage)

        def run(cwd, args):
            result = subprocess.run(
                [dune, *args],
                cwd=cwd,
                env=clean,
                capture_output=True,
                text=True,
                timeout=300,
            )
            require(result.returncode == 0, (args, result.stdout, result.stderr))

        prefix = root / "installed"
        run(stage, ["build", "@install"])
        run(
            stage,
            ["install", "--prefix", str(prefix), *packages.values()],
        )
        clean["OCAMLPATH"] = str(prefix / "lib") + os.pathsep + str(deps)
        consumer = root / "consumer"
        project(consumer)
        shutil.copy2(
            ROOT / "test/web_eio/runtime_test.ml", consumer / "runtime_test.ml"
        )
        shutil.copy2(ROOT / "test/db_eio/db_test.ml", consumer / "db_test.ml")
        shutil.copy2(ROOT / "test/web/web_test.ml", consumer / "web_test.ml")
        # Pure helpers must compile with no runtime library explicitly linked.
        (
            consumer / "dune"
        ).write_text("""(executable (name web_test) (modules web_test) (modes byte exe) (libraries httpkit))
(executable (name runtime_test) (modules runtime_test) (modes byte exe) (libraries httpkit-eio eio_main))
(executable (name db_test) (modules db_test) (modes byte exe) (libraries httpkit-db-eio eio_main))
""")
        run(consumer, ["build", "@all"])
        for name in ["web_test", "runtime_test", "db_test"]:
            for mode in ["exe", "bc"]:
                executable = consumer / f"_build/default/{name}.{mode}"
                args = (
                    [str(executable)]
                    if mode == "exe"
                    else [str(compiler.with_name("ocamlrun")), str(executable)]
                )
                result = subprocess.run(
                    args,
                    cwd=consumer,
                    env=clean,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                require(
                    result.returncode == 0, (name, mode, result.stdout, result.stderr)
                )
        for source in [
            'let _ : Httpkit.Html.t = "<script>"',
            "let _ = Lwt.return_unit",
        ]:
            (consumer / "forged.ml").write_text(source + "\n")
            (consumer / "dune").write_text(
                "(executable (name forged) (modules forged) (libraries httpkit-eio))\n"
            )
            result = subprocess.run(
                [dune, "build", "forged.exe"],
                cwd=consumer,
                env=clean,
                capture_output=True,
                text=True,
                timeout=30,
            )
            require(
                result.returncode != 0
                and (
                    "Httpkit.Html.t" in result.stderr
                    or "Unbound module Lwt" in result.stderr
                ),
                result.stderr,
            )
    print(
        "PASS installed web/Eio/database consumers: native, bytecode, opaque HTML and no Lwt"
    )


if __name__ == "__main__":
    main()
