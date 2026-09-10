#!/bin/sh
# Optional interop reference, installed only inside this checkout.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
read -r source_url source_sha < "$task_root/toolchain/nginx.version"
archive="$task_root/.toolchain/nginx-1.30.4.tar.gz"
mkdir -p "$task_root/.toolchain"
if [ ! -f "$archive" ]; then curl --fail --location --silent --show-error "$source_url" -o "$archive.tmp"; mv "$archive.tmp" "$archive"; fi
actual_sha=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
[ "$actual_sha" = "$source_sha" ] || { echo 'Nginx archive checksum mismatch' >&2; exit 1; }
build_dir=$(mktemp -d "$task_root/.toolchain/nginx-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
tar -xzf "$archive" -C "$build_dir"
cd "$build_dir/nginx-1.30.4"
./configure --prefix="$task_root/.toolchain/nginx" --without-http_rewrite_module --without-http_gzip_module
make -j4
make install
