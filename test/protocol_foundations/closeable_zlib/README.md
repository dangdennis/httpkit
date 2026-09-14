# Private closeable gzip experiment

Derived from the inflate-reader portion of Bytesrw 0.4.0, ISC licensed; see
LICENSE.md. The upstream release SHA512 is recorded in dune.lock/bytesrw.0.4.0.pkg.
This test-only library calls the pinned upstream private zlib C ABI. It is not
installed, a supported extension API, or a production backend decision.

Changes: return an idempotent close callback; make failure terminal while
preserving exception/backtrace; reject overlapping reads; recheck closed state
after source callbacks resume; allocate the output buffer before native state.
The close callback calls upstream free_inflate_z_stream, whose implementation
calls inflateEnd and clears its native pointer; the finalizer is then inert.
No new codec or C implementation is introduced. This is a one-domain prototype.

A supported upstream API or a separately reviewed ownership layer is required
before adoption. Cancellation tests cover Eio input suspension and Lwt consumer
suspension. Native allocation instrumentation, cross-domain behavior, all
suspension points and maintained native-library policy remain unproved.
