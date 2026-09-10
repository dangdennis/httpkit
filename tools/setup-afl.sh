#!/bin/sh
# Install only the native AFL++ tools used with OCaml's own instrumentation.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
read -r repository tag revision extra < "$task_root/toolchain/afl.version"
[ -z "${extra:-}" ] && [ "${#revision}" -eq 40 ] || exit 2
case "$revision" in *[!0-9a-f]*) exit 2 ;; esac
case "$repository" in https://github.com/AFLplusplus/AFLplusplus.git) ;; *) exit 2 ;; esac
task_afl="$task_root/.toolchain/afl"
mkdir -p "$task_root/.toolchain"
if [ ! -d "$task_afl" ]; then
  git clone --depth 1 --branch "$tag" -- "$repository" "$task_afl"
fi
# A moved tag or an unrelated checkout must fail instead of silently changing
# the fuzzer that produced our security evidence.
[ "$(git -C "$task_afl" rev-parse HEAD)" = "$revision" ] || {
  echo 'AFL revision mismatch; restore the pinned checkout before setup' >&2
  exit 2
}
git -C "$task_afl" diff --quiet HEAD -- || {
  echo 'AFL tracked sources have local changes; refusing to certify this build' >&2
  exit 2
}
make -C "$task_afl" -j4 afl-fuzz afl-showmap AFL_NO_X86=1
printf 'AFL++ %s ready in %s\n' "$tag" "$task_afl"
