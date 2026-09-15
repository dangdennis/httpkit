# The amd64 manifest is immutable; its OCaml 5.5.1 only bootstraps Dune.
# The project lock builds and checks OCaml 5.5.0 during validation.
FROM ocaml/opam@sha256:ca39555d59632efc3bad5fef060b862571200502a0cf0bd2d27492622bfe1981
USER root
RUN timeout 900 sh -c 'apt-get update && apt-get install -y --no-install-recommends pkg-config libgmp-dev libffi-dev libssl-dev libsqlite3-dev libpq-dev libargon2-dev zlib1g-dev libev-dev postgresql openssl curl git ca-certificates rsync lsof time make gcc g++ m4 perl patch unzip xz-utils && rm -rf /var/lib/apt/lists/*'
USER opam
RUN timeout 1800 sh -c 'opam repository set-url default git+https://github.com/ocaml/opam-repository.git#5d711cd97e038d93464ab855e041c0ff624c9d07 --all-switches -y && opam install -y --jobs=4 dune.3.24.1 && opam exec -- dune --version'
