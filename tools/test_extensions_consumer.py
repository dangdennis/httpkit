#!/usr/bin/env python3
"""Install every extension, then run native and ordinary ocamlrun consumers."""

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
        return subprocess.check_output(command(dune, env, args), cwd=ROOT,
                                       env=env, text=True, timeout=1800).strip()

    compiler = Path(locked(["exec", "--", "sh", "-c", "command -v ocamlc"])).resolve()
    ocamlfind = locked(["exec", "--", "sh", "-c", "command -v ocamlfind"])
    names = ["eio_main", "lwt.unix", "ipaddr", "yojson", "base64", "digestif",
             "eqaf", "mtime.clock.os", "caqti-eio.unix", "caqti-driver-postgresql",
             "caqti-driver-sqlite3", "argon2", "oidc", "jose", "mirage-crypto-rng.unix",
             "mirage-crypto-pk", "dune-configurator"]
    with tempfile.TemporaryDirectory(prefix="httpkit-extension-consumer-") as temporary:
        root = Path(temporary)
        clean = {k: v for k, v in env.items() if not k.startswith(("OCAML", "CAML", "DUNE"))}
        clean["PATH"] = str(compiler.parent) + os.pathsep + clean["PATH"]
        paths = {Path(p) for p in locked(["exec", "--", "ocamlfind", "query", "-recursive", "-format", "%d", *names]).splitlines()}
        def package_root(path):
            while (path.parent / "META").is_file() or (path.parent / "dune-package").is_file():
                path = path.parent
            return path

        paths = {package_root(p) for p in paths}
        paths = {p for p in paths if not any(q != p and q in p.parents for q in paths)
                 and compiler.parent.parent not in p.parents}
        deps = root / "deps"
        deps.mkdir()
        for path in paths:
            shutil.copytree(path, deps / path.name)
            if (path.parent / "stublibs").is_dir():
                shutil.copytree(path.parent / "stublibs", deps / "stublibs", dirs_exist_ok=True)
        clean["OCAMLPATH"] = str(deps)
        stdlib = subprocess.check_output([str(compiler), "-where"], env=clean, text=True).strip()
        findlib_conf = root / "findlib.conf"
        findlib_conf.write_text(f'path="{deps}:{stdlib}"\nstdlib="{stdlib}"\n')
        clean["OCAMLFIND_CONF"] = str(findlib_conf)
        clean["CAML_LD_LIBRARY_PATH"] = os.pathsep.join({str(p.parent) for p in deps.rglob("dll*.so")})

        def project(path):
            path.mkdir()
            (path / "dune-project").write_text("(lang dune 3.24)\n(name installed-extensions)\n")
            (path / "dune-workspace").write_text("(lang dune 3.24)\n(pkg disabled)\n")

        def run(cwd, args):
            result = subprocess.run(args, cwd=cwd, env=clean, capture_output=True, text=True, timeout=300)
            require(result.returncode == 0, (args, result.stdout, result.stderr))

        source = root / "source"
        project(source)
        shutil.copytree(ROOT / "lib", source / "lib")
        packages = [p for p in ROOT.glob("httpkit*.opam") if p.stem != "httpkit-harness"]
        for p in packages:
            shutil.copy2(p, source / p.name)
        prefix = root / "installed"
        run(source, [dune, "build", "@install"])
        run(source, [dune, "install", "--prefix", str(prefix), *[p.stem for p in packages]])
        clean["OCAMLPATH"] = str(prefix / "lib") + os.pathsep + str(deps)
        clean["CAML_LD_LIBRARY_PATH"] = os.pathsep.join({str(p.parent) for directory in (deps, prefix / "lib") for p in directory.rglob("dll*.so")})
        consumers = {
            "auth_test": "httpkit-cookie httpkit-password httpkit-oidc mirage-crypto-rng.unix mirage-crypto-pk",
            "sql_session_test": "httpkit-session-eio eio_main caqti-eio mirage-crypto-rng.unix",
            "lwt_app_test": "httpkit-lwt lwt.unix mirage-crypto-rng.unix",
            "oidc_eio_test": "httpkit-oidc-eio eio_main mirage-crypto-rng.unix mirage-crypto-pk",
        }
        for name, libraries in consumers.items():
            consumer = root / name
            project(consumer)
            shutil.copy2(ROOT / "test/extensions" / (name + ".ml"), consumer)
            (consumer / "dune").write_text(f"(executable (name {name}) (modes byte exe) (libraries {libraries}))\n")
            run(consumer, [dune, "build", name + ".exe", name + ".bc"])
            run(consumer, [str(consumer / "_build/default" / (name + ".exe"))])
            run(consumer, [str(compiler.with_name("ocamlrun")), str(consumer / "_build/default" / (name + ".bc"))])
            print("PASS installed native/bytecode:", name, flush=True)
        # Inspect each installed library's declared closure, not just all copied dependencies.
        for package, forbidden in [("httpkit-lwt", "eio"), ("httpkit-oidc-eio", "lwt"),
                                   ("httpkit-cookie", "eio"), ("httpkit-password", "lwt")]:
            result = subprocess.check_output([ocamlfind, "query", "-recursive", "-format", "%p", package], env=clean, text=True)
            require(not any(p == forbidden or p.startswith(forbidden + ".") for p in result.splitlines()), (package, result))
        print("PASS extension dependency isolation")


if __name__ == "__main__":
    main()
