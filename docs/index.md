# Documentation

Start with [validation status](status.md), then [internal adoption](internal-use.md).

| Goal | Read |
| --- | --- |
| Install a pinned source version | [Installation](beta-install.md) |
| Build an application | [Eio application guide](framework.md), [Lwt and extensions](extensions.md), [examples](examples.md) |
| Make outbound requests | [Streaming HTTP/HTTPS client](client.md) |
| Understand library boundaries | [Package design](design.md), [HTTP/1](http1.md), [engine](engine.md), [adapters](adapters.md) |
| Configure application behavior | [Routing](routing.md), [middleware](middleware.md), [limits](production-limits.md), [observability](observability.md) |
| Develop and test | [Development](development.md), [local platforms](local-validation.md), [tooling](tooling.md), [native fuzzing](native-fuzz.md) |
| Measure performance | [Benchmark methodology](benchmarks.md), [profiling investigation](profiling-hang.md) |
| Prepare deployment and release | [Deployment contract](deployment.md), [release evidence](release.md), [beta plan](beta-plan.md) |

Plans, audits and dated benchmark reports explain decisions and historical work.
They are not live readiness dashboards; [status](status.md) is the current summary.
Generated API documentation lives under `_build-pkg-5.5.0/default/_doc/_html/`
after `mise run docs`.
