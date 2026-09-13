# Using http-kit with Eio

These examples target OCaml 5.5.0. Build from the repository using the
[development setup](development.md).

## Stream in both directions

```sh
tools/dune-pkg exec examples/personal/eio_streaming.exe
```

The [source](../examples/personal/eio_streaming.ml) streams 1 MiB each way over an
Eio socket pair. It retains one 8 KiB producer chunk, checks every incoming chunk,
and limits each engine's output queue to 32 KiB. `Complete` marks incoming body
completion; `finish` finalizes outgoing framing. Chunked messages may emit
`Trailers` before `Complete`. Neither operation means all output has drained;
`with_connection` flushes accepted output on normal callback return.

The installed-consumer check compiles and runs this source in native and bytecode
forms with Lwt unavailable:

```sh
python3 tools/test_adapter_consumer.py
```

## Cancel a blocked operation

```sh
tools/dune-pkg exec examples/personal/eio_cancel.exe
```

The [cancellation example](../examples/personal/eio_cancel.ml) waits until a native
read is blocked, cancels its scope, and verifies that the read terminates and the
transport closes exactly once. The peer remains open during cancellation, so EOF
cannot accidentally make the check pass.

## Run the application

```sh
tools/dune-pkg exec examples/personal/eio_server.exe
```

The [server](../examples/personal/eio_server.ml) prints its loopback port. It uses
pure routing and Basic middleware, with these endpoints:

| Endpoint | Behavior |
| --- | --- |
| `GET /health` | Small `ok` response |
| `POST /upload` | Incrementally counts bytes and a checksum; accepts up to 1 MiB |
| `GET /download` | Streams 2 MiB through bounded writes |
| `GET /stats` | Connection counts and post-GC heap observations for this example |

For example, substitute the printed port:

```sh
curl http://127.0.0.1:PORT/health
curl --data-binary @your-file http://127.0.0.1:PORT/upload
curl http://127.0.0.1:PORT/download --output /dev/null
```

Type `stop` and Enter in the server terminal to stop admission and drain active
exchanges. Incomplete exchanges are cancelled at the graceful deadline; all owned
transports must close before exit. Peer disconnects abort their connection without
stopping other workers. An application callback doing unrelated work needs its own
cancellation/deadline scope.

The example admits at most 16 connections with a listener backlog of 32, a 32 KiB
output queue per connection, and the adapter's default deadlines (10 s headers,
30 s body/write idle, 30 s keep-alive and 10 s graceful shutdown). Codec body limits
apply in both directions: its 2 MiB quota accommodates downloads; the application
separately enforces the stricter 1 MiB upload cap. Early route rejection does not
wait for an Expect client to upload. Exceeding a streamed upload quota aborts the
connection; this example does not promise a 413 response after partial input.

`/stats` forces a major collection to observe retained heap and is a test endpoint,
not something to expose in an application. The example binds only to loopback.
TLS and application authentication remain caller responsibilities.

## Exercise and measure it

```sh
python3 tools/personal_use.py --mode smoke
python3 tools/personal_use.py --mode profile --seconds 10
python3 tools/personal_use.py --mode soak --seconds 7200
python3 tools/campaign.py --seconds 1800
```

The profile runs 1, 4 and 8 concurrent clients for the specified duration each.
The soak uses four clients and a target of 20 operations/second, including fixed
and chunked uploads, normal and slow downloads, connection resets and reuse. It
observes cleanup, descriptors, post-GC live heap and RSS between 60-second epochs,
then verifies graceful shutdown with active transfers. Reports and server logs
are retained under `_artifacts/personal/`; failures remain failures.

RSS sampling uses `ps`, and descriptor observation uses `/proc` on Linux or `lsof`
on macOS. These require local process-observation access. Latencies include the
intentional slow reads; reports identify histogram upper bounds rather than
inventing precise percentiles. Local profiles are advisory and include Python
client overhead. This is not a comparison against another HTTP implementation.

Personal-use resource budgets are 256 MiB observed server RSS, at most 32 MiB
post-warmup RSS growth, at most 1 MiB post-GC live heap variation, and at most two
descriptors of variation at quiescent checkpoints. These are conservative test
budgets for this workload; passing them is not proof of absence of small leaks.
Inspect the retained trends as well. Engine queue bounds have separate exact
checks. The initial reference observation precedes warmup; the first two
observations are excluded from growth comparisons.

The nine 30-minute fuzz targets run sequentially (about 4.5 hours plus setup and
corpus replay). They retain the original 512 MiB and 2-second execution limits.
Source changes invalidate final evidence. Neither these budgets nor the personal
profile replaces the [public-release requirements](release.md).

To run the complete local sequence and both approved long experiments:

```sh
python3 tools/personal_validation.py --long
```

This runs baseline validation first, then the nine sequential AFL targets alongside
the two-hour Eio soak. The performance profile runs before AFL starts. It writes
step logs and a durable report under `_artifacts/personal/validation-*`. A failed
step stops the sequence; interrupted long-run process groups are terminated.
The historical timeout remains separately visible as unresolved even when new
experiments pass; no readiness tag is created automatically.
