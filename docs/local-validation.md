# Local platform validation

Hosted CI is currently unavailable and excluded from this work. Use local
validation; a successful push does not establish a passing build or release.

The macOS arm64 path is `tools/dev validate`, followed by `tools/dev databases`
for the isolated PostgreSQL/SQLite integration checks. The latter starts its own
local database and tears it down. No AFL is included in these commands.

## Linux x86_64 with Docker

The checked-in image recipe pins an amd64 Debian base and the repository used
to install Dune3.24.1. The image's5.5.1 compiler only bootstraps Dune: the project
lock builds OCaml5.5.0 and the runner asserts that exact version. A moving `5.5`
image tag is not proof of5.5.0. OS packages are resolved during image construction,
so retain the resulting image ID and package inventory; this is not a claim of
bit-for-bit reproducible apt resolution.

Start from a clean committed checkout. The runner clones it into the container;
the host checkout is mounted read-only, and uncommitted changes are rejected.
From the repository root:

```sh
docker build --platform linux/amd64 -t httpkit-local-validation \
  -f toolchain/linux/Dockerfile toolchain/linux
mkdir -p _artifacts/linux-local
docker image inspect httpkit-local-validation > _artifacts/linux-local/image.json
docker run --name httpkit-linux-validation --platform linux/amd64 --init \
  --cpus 4 --memory 4g --memory-swap 4g --pids-limit 512 \
  --mount "type=bind,source=$PWD,target=/source,readonly" \
  --mount "type=bind,source=$PWD/toolchain/linux/validate.sh,target=/runner/validate.sh,readonly" \
  httpkit-local-validation \
  timeout --signal=TERM --kill-after=30s 43200 sh /runner/validate.sh \
  > _artifacts/linux-local/run.log 2>&1
```

The run has a12-hour outer limit. Record a nonzero exit as failure. Preserve its
log even if setup failed before reports existed. After completion, inspect the
exit state and copy any reports before removing this task's container:

```sh
docker inspect --format '{{json .State}}' httpkit-linux-validation \
  > _artifacts/linux-local/state.json
docker cp httpkit-linux-validation:/home/opam/httpkit/_artifacts \
  _artifacts/linux-local/reports
docker rm httpkit-linux-validation
```

If the terminal or client is interrupted, explicitly stop that named container
(`docker stop --time 30 httpkit-linux-validation`) before collecting evidence.
An interrupted client does not guarantee the Docker daemon stopped the job.
Use a different name/output directory for each retained run; do not overwrite
failed evidence or remove unrelated containers/images.

The selected Eio backend is explicitly `posix`; `io_uring` is a separate,
unverified platform boundary. On an arm64 Docker host this is emulated x86_64
compatibility evidence, not native Linux performance evidence. Record the Docker
host architecture as well as the container architecture. These commands do not
run the long fuzz/soak campaigns, establish hosted deployment behavior or satisfy
every release gate. Keep source/compiler/image identities attached to results.

The first clean-clone run on `9dc7e2f` built 5.5.0 and reached the fast scenario suite,
but failed because the validation coordinator had not created `_artifacts`
before writing reports. The coordinator now creates its owned output directory.
That failed run remains historical evidence; it is not a Linux acceptance pass.
Later Linux checks passed on other candidates; see [current status](status.md)
for their scope and source identities.
