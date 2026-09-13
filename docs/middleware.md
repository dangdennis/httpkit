# Middleware: choose the context guarantee you need

`httpkit-middleware` depends only on core. It provides three related styles, not
three competing application frameworks. Every style preserves the request body
and handler output types. Wrappers may return a response, a result, or a native
runtime promise. No body is read, closed, or copied by the combinators.

| Style | Handler shape | Type guarantee |
| --- | --- | --- |
| `Basic` | request → output | Compatible request body and output types. Context requirements are not represented. |
| `Context` | context → request → output | Every wrapper agrees on one explicit application context type. |
| `Transition` | accepts context A, supplies context B to the next handler | Adjacent context transitions must agree; the endpoint receives the context type it requires. |

## Composition order

`Basic.chain [a; b] endpoint` is `a (b endpoint)`. For conventional wrappers,
request work enters `a`, then `b`, then the endpoint; synchronous response work
returns through `b`, then `a`. A wrapper can return without calling the endpoint.
The empty chain is identity. Construct a reusable chain once, outside the request
loop. Middleware factories should not perform request-specific work when assembled.

`Context.chain` follows the same rule with a typed context argument. A context
record containing `user : user option` remains optional at every step; this style
does not prove a previous wrapper populated the field.

## Context transitions

A transition pipeline might accept `anonymous`, produce `authenticated`, then
produce `authorized` before reaching its endpoint:

```ocaml
let handler =
  Transition.compose authenticate authorize protected_endpoint
```

Each step has the shape `next -> context -> request -> output`. Compose different
context types pairwise. A homogeneous list cannot represent an arbitrary sequence
of distinct context transitions; `Transition.compose` exposes that constraint instead
of erasing it with casts or dynamic dictionaries. Reversing incompatible steps or
skipping a required transition fails compilation.

`Transition.guard decide ~reject` is a convenience for synchronous decisions. It
calls `decide` once and then either `next` once with the new context or `reject`
once. `map_context` derives a context; `lift` incorporates a context-preserving
wrapper. Applications can define abstract authenticated/authorized types to limit
which modules may construct those values.

These types check context plumbing, not whether an authorization decision is
correct. OCaml also does not enforce single use of arbitrary continuations: a
custom wrapper must respect one-shot body/endpoint ownership. Exceptions propagate;
there is no implicit retry, recovery, resource cleanup, or response framing.

## Native runtime use

For Eio, write an ordinary wrapper that performs Eio operations before calling
`next`. For Lwt, use `let*` inside the wrapper and keep the output type as a native
Lwt promise. The combinators neither bind nor inspect that promise. Response work
that should run after an asynchronous endpoint must be inside the runtime's bind;
calling `next` merely obtains the promise. Cancellation and resource scopes remain
owned by the adapter/application.

## Executable example

```sh
tools/dune-pkg exec ./examples/middleware/styles.exe
tools/dev consumer middleware
```

[The example](../examples/middleware/styles.ml) demonstrates all three styles and
a short-circuiting rejection. Its literal token is only a test fixture. The
installed-consumer check compiles the exact example in native and bytecode modes,
with only core and middleware installed. Negative fixtures check mismatched
contexts, skipped transitions and reversed composition. Runtime tests cover
nesting, context flow, short-circuiting, exception propagation and opaque results.
