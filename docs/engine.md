# Sans-I/O engine ownership

`http-kit-engine` composes core values and strict HTTP/1 codecs. Client and server instances have one owner; calls perform no I/O, clock reads, scheduler effects, or application callbacks. The API is in `lib/engine/http_kit_engine.mli`.

## Admission and events

Each connection admits one exchange. A server stops at the first head; later pipeline bytes remain in the caller's suffix until incoming/outgoing bodies finish and output is acknowledged. This supports ordered pipelined input without an unbounded request queue.

IDs contain a local sequence number and connection identity. Equal numbers from different engines cannot be interchanged. Retaining an ID does not retain the entire engine. IDs cannot be fabricated through the public API.

At most one incoming event is pending. Data events own copied strings bounded by the codec step limit. Not polling an event backpressures input. Polling can advance an already-buffered End but never reads a transport. `input_state` distinguishes idle/head/body input, blocking, and closure; adapters must not start reads while blocked. This prevents speculative reads from stealing post-handshake bytes.

Complete reports incoming body completion once, separately from outgoing finish. An exchange retires only after both directions finish, output drains, and pending completion events are delivered.

## Commands and output

Backpressured commands have no effect and may be retried. Accepted commands must not be retried. Metadata is checked before admission. Body misuse after commitment aborts the exchange; no second error response is inserted into a body.

Output is a FIFO of immutable strings and a current offset. Polling returns a stable slice; acknowledgement retires only a prefix of that slice. Invalid counts leave it unchanged. The default queue limit is 64 KiB. Reservations include conservative framing overhead before the body encoder mutates; a command too large ever to fit fails rather than returning permanent backpressure. `max_send_size` lets adapters split user data into admissible chunks.

The input counter reports pending engine-owned Data payload. The output counter
includes queued serialized headers, framing and payload. Codec metadata, queue nodes, bookkeeping and adapter staging add bounded overhead. Application-retained events are outside engine ownership. Independent instances may run on different domains; one instance must not be mutated concurrently.

## Early responses and shutdown

A final server response before upload completion aborts the incoming body, emits Body_aborted, and forces close after output drains. Unread upload bytes never become a new request. Explicit discard instead consumes and checks framing to Complete before safe reuse.

A client receiving an early final response stops an unfinished upload, drops unsent queued upload bytes, and prevents reuse. It never transparently retries. Expect blocks body commands until a 100 response or explicit `continue_request` policy decision. Informational responses have a configurable finite count, default 16.

Shutdown stops admission and closes after the active exchange finishes. An adapter owns its deadline and aborts on expiry. Abort is idempotent, preserves the first failure, drops pending work and exposes one Closed event. A peer half-close after a complete request still permits the server to finish its response.

## Handoff

CONNECT and 101 responses require matching request context. Upgrade selection must be offered and both Connection headers must nominate upgrade. Handoff cannot cross an unfinished HTTP request body. Handoff is emitted only after required HTTP output is acknowledged. The caller transfers the transport and unconsumed suffix together; HTTP parsing cannot resume afterward.

## Evidence

The suite tests both roles, pipeline suffixes, input/output backpressure, stale/foreign IDs, early responses, discard, informational/Expect behavior, abort/EOF/shutdown, invalid acknowledgement, body mismatch, readiness, and handoff. An independent model checks acknowledged bytes against a literal expected prefix under generated command schedules. A client model checks fragmented response identity/order. Independent connections are tested on 1, 2, and 4 domains.

Native AFL targets reuse these models; the runner preserves findings and replays queue entries without instrumentation. The installed engine consumer runs in bytecode/native modes without runtime adapters. The native adapter suites establish transport, deadline, cancellation and cleanup behavior; pure engine tests do not establish those properties.

Expect gates both payload writes and final framing, including empty-body
finalization. Backpressure leaves the writer and output queue unchanged.

## Internal transition boundaries

Receive and send progress are separate private variants. Notification delivery
and output draining are separate from both; this preserves duplex behavior.

| Trigger | Receive state | Send state | Retirement condition |
| --- | --- | --- | --- |
| Client submits head | Awaiting head | Writing | Wait for response and output |
| Server receives head | Reading, or Received if empty | Awaiting response | Deliver request and incoming Complete |
| Incoming body End | Received | Unchanged | Deliver Complete once |
| Outgoing finish | Unchanged | Sent | Drain queued bytes |
| Server early final | Aborted input | Writing | Emit Body_aborted; force close after output |
| Client early final | Reading response | Sent | Drop unsent upload; force close |
| Valid handoff response | Terminal HTTP input | Sent | Drain HTTP output before Handoff |

`complete_input`, `abort_input` and `complete_output` establish the related
invariants together. Discard changes retention policy while preserving framing
validation and the normal incoming completion transition.
