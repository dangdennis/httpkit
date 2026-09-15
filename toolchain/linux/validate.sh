#!/bin/sh
# Runs in an ephemeral container with the committed checkout mounted read-only.
set -eu
source_git() {
  git -c safe.directory=/source -c safe.directory=/source/.git -C /source "$@"
}
if [ -n "$(source_git status --porcelain --untracked-files=normal)" ]; then
  echo 'Commit the candidate before Linux validation; the source must be clean.' >&2
  exit 2
fi
httpkit_revision=$(source_git rev-parse HEAD)
git -c safe.directory=/source -c safe.directory=/source/.git clone --no-local /source /home/opam/httpkit
cd /home/opam/httpkit
test "$(git rev-parse HEAD)" = "$httpkit_revision"
test -z "$(git status --porcelain)"
printf 'Source commit: %s\n' "$httpkit_revision"
mkdir -p .toolchain/bin
opam exec -- sh -c 'cp "$(command -v dune)" .toolchain/bin/dune'
export EIO_BACKEND=posix
printf 'Eio backend: %s\n' "$EIO_BACKEND"
uname -a
dpkg-query -W
tools/dune-pkg build -j 4 tools/dev.exe
httpkit_compiler=$(tools/dune-pkg exec -- ocamlc -version)
printf 'Project compiler: %s\n' "$httpkit_compiler"
test "$httpkit_compiler" = 5.5.0
tools/dev validate
exec tools/dev databases
