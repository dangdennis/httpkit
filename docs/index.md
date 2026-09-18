# Documentation

Start with [a new application](internal-use.md) for GitHub installation, routes,
and SQLite or PostgreSQL. Check [validation status](status.md) before choosing a
version. APIs and production readiness remain experimental.

## Build an application

| Task | Guide |
| --- | --- |
| Install a pinned source version | [New-repository tutorial](internal-use.md), [package installation](beta-install.md) |
| Choose packages and understand dependencies | [Package design](design.md) |
| Add handlers, streaming, middleware and a database | [Eio applications](framework.md) |
| Add sessions, passwords, OIDC or Lwt handlers | [Extensions](extensions.md) |
| Make HTTP/HTTPS requests | [Streaming client](client.md) |
| Run smaller examples | [Example catalog](examples.md), [Eio streaming and cancellation](personal-eio.md) |
| Prepare a hosted application | [Deployment and proxy trust](deployment.md) |

## Understand the contracts

| Topic | Reference |
| --- | --- |
| Framing, incremental I/O and connection state | [HTTP/1](http1.md), [engine](engine.md), [native adapters](adapters.md) |
| Request matching and handler composition | [Routing](routing.md), [middleware](middleware.md) |
| Resource ownership and cancellation | [Lifecycle](lifecycle.md) |
| Admission, byte budgets and timeouts | [Limits](production-limits.md) |
| Metrics and event semantics | [Observations](observability.md) |

## Develop and validate

| Task | Guide |
| --- | --- |
| Set up the checkout and build API docs | [Development](development.md) |
| Choose checks and interpret their scope | [Testing](testing.md), [CLI reference](tooling.md) |
| Run Linux/macOS checks | [Local platform validation](local-validation.md) |
| Understand the synthetic scenario harness | [Harness contract](harness-contract.md) |
| Generate, replay and minimize inputs | [Native fuzzing](native-fuzz.md) |
| Measure primitive costs and compare libraries | [Benchmarks](benchmarks.md), [measurement backlog](benchmark-todos.md) |
| Measure endpoints, overload and adverse clients | [Load testing](load-testing.md), [interop](interop-performance.md) |

## Readiness and maintenance

[Status](status.md) is the current evidence summary.
[Release policy](release.md) defines acceptance; [beta scope](beta-plan.md) defines
publication scope. [Dependency review](dependencies.md) records the reviewed
versions and limits. Report vulnerabilities through [SECURITY.md](../SECURITY.md).

Open investigation records: [profiling hang](profiling-hang.md) and
[historical fuzz timeouts](request-timeout-investigation.md). The PostgreSQL
bytecode crash is recorded in [status](status.md#what-we-found).
[Dependency experiments](protocol-foundations.md) remain development research.

[Archived plans and reports](archive/index.md) retain useful history. They do not
supply current commands or acceptance. Keep each contract in its reference guide,
commands in the development guides, and dated results in status or the archive.
