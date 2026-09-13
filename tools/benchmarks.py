#!/usr/bin/env python3
"""Repeat native OCaml workloads; retain samples and compare compatible reports."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import random
import statistics
import subprocess
import tempfile

from dune_env import ROOT, command, configuration, require_lock
from evidence import source_hash

FAMILIES = (
    "all",
    "core",
    "router",
    "http1",
    "middleware",
    "engine",
    "body",
    "exchange",
    "router-experiment",
)
SCHEMA = 1
EXTERNAL_IMPLEMENTATIONS = {
    "router": {"httpkit", "routes"},
    "http1": {"httpkit", "httpaf", "httpun"},
    "body": {"httpkit", "httpaf", "httpun"},
    "exchange": {"httpkit", "httpaf", "httpun"},
    "router-experiment": {"httpkit", "prefix-index", "deep-index"},
}


def need(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, positive=False):
    return (
        type(value) in (int, float)
        and math.isfinite(value)
        and (value > 0 if positive else value >= 0)
    )


def inventory(rows):
    need(isinstance(rows, list) and rows, "empty workload catalog")
    catalog = {}
    for row in rows:
        case = row["id"]
        need(
            isinstance(case, str) and case not in catalog,
            "duplicate or invalid case id",
        )
        need(
            row["family"] in FAMILIES[1:] and case.startswith(row["family"] + "/"),
            "invalid family",
        )
        need(
            type(row["iterations"]) is int and row["iterations"] > 0,
            "invalid iterations",
        )
        need(
            type(row["bytes_per_op"]) is int and row["bytes_per_op"] >= 0,
            "invalid byte count",
        )
        catalog[case] = {
            key: row[key] for key in ("id", "family", "iterations", "bytes_per_op")
        }
        if "base_iterations" in row:
            need(
                type(row["base_iterations"]) is int
                and 0 < row["base_iterations"] <= row["iterations"] <= 10000000,
                "invalid calibrated iterations",
            )
            catalog[case]["iterations"] = row["base_iterations"]
        if "comparison" in row or "implementation" in row:
            need(
                row.get("implementation")
                in EXTERNAL_IMPLEMENTATIONS.get(row["family"], set())
                and isinstance(row.get("comparison"), str)
                and row["comparison"],
                "invalid comparison labels",
            )
            need(
                case
                == f"{row['family']}/external/{row['comparison']}/{row['implementation']}",
                "comparison id differs",
            )
            catalog[case].update(
                comparison=row["comparison"], implementation=row["implementation"]
            )
    return catalog


def library_comparisons(results, samples):
    groups = {}
    for row in results:
        if "comparison" not in row:
            continue
        group = groups.setdefault((row["family"], row["comparison"]), {})
        need(row["implementation"] not in group, "duplicate comparison implementation")
        group[row["implementation"]] = row
    comparisons = []
    indexed = [{r["id"]: r for r in sample["results"]} for sample in samples]
    for (family, workload), implementations in sorted(groups.items()):
        need(
            set(implementations) == EXTERNAL_IMPLEMENTATIONS[family],
            "incomplete library comparison",
        )
        ours = implementations["httpkit"]
        for implementation, other in sorted(implementations.items()):
            need(
                (ours["iterations"], ours["bytes_per_op"])
                == (other["iterations"], other["bytes_per_op"]),
                "comparison workload sizes differ",
            )
            if implementation == "httpkit":
                continue
            # Each process contains every implementation. Pair within that
            # process before summarizing ratios; do not pool unrelated cases.
            ratios = [
                s[other["id"]]["ns_per_op"] / s[ours["id"]]["ns_per_op"]
                for s in indexed
            ]
            comparisons.append(
                dict(
                    family=family,
                    workload=workload,
                    implementation=implementation,
                    httpkit_ns_per_op=ours["median_ns_per_op"],
                    other_ns_per_op=other["median_ns_per_op"],
                    median_other_over_httpkit_time_ratio=statistics.median(ratios),
                    sample_time_ratios=ratios,
                    httpkit_allocated_bytes_per_op=ours[
                        "median_allocated_bytes_per_op"
                    ],
                    other_allocated_bytes_per_op=other["median_allocated_bytes_per_op"],
                )
            )
    return comparisons


def locked_comparison_versions(lock):
    versions = {}
    for name in (
        "routes",
        "httpaf",
        "httpun",
        "httpun-types",
        "angstrom",
        "bigstringaf",
        "faraday",
    ):
        matches = list(lock.glob(name + ".*.pkg"))
        need(len(matches) == 1, f"missing or ambiguous locked library: {name}")
        versions[name] = re.search(r"\(version ([^)]+)\)", matches[0].read_text())[1]
    return versions


def validate_exclusions(exclusions, catalog):
    timed = {(r["family"], r.get("comparison")) for r in catalog}
    seen = set()
    for group in exclusions:
        key = (group["family"], group["comparison"])
        need(
            group["family"] == "body"
            and isinstance(group["comparison"], str)
            and group["comparison"]
            and key not in seen
            and key not in timed,
            "invalid or timed exclusion",
        )
        seen.add(key)
        need(
            sorted(group["excluded_implementations"])
            == ["httpaf", "httpkit", "httpun"],
            "partial group exclusion",
        )
        observations = group["observations"]
        need(
            isinstance(observations, list) and observations,
            "missing exclusion observation",
        )
        implementations = set()
        for observation in observations:
            impl = observation["implementation"]
            need(
                impl in ("httpaf", "httpun") and impl not in implementations,
                "invalid excluded observer",
            )
            implementations.add(impl)
            need(
                type(observation["consumed_bytes"]) is int
                and type(observation["wire_bytes"]) is int
                and 0 <= observation["consumed_bytes"] < observation["wire_bytes"],
                "invalid exclusion byte counts",
            )
            need(
                isinstance(observation["reason"], str) and observation["reason"],
                "missing exclusion reason",
            )


def median_interval(times):
    # Descriptive bootstrap interval across independent process means, never
    # a request-latency percentile or evidence that the host was isolated.
    rng = random.Random(7331)
    medians = sorted(
        statistics.median(rng.choices(times, k=len(times))) for _ in range(2000)
    )
    return [medians[49], medians[1949]]


def aggregate(samples, catalog, compiler, quick):
    expected = inventory(catalog)
    need(len(samples) >= 2, "at least two independent samples required")
    for sample in samples:
        need(
            number(sample.get("min_ms", 0)) and sample.get("min_ms", 0) <= 1000,
            "invalid calibration duration",
        )
        need(
            not (quick and sample.get("min_ms", 0)), "quick sample cannot be calibrated"
        )
        need(
            sample["schema"] == SCHEMA
            and sample["compiler"] == compiler
            and sample["quick"] is quick,
            "incompatible sample metadata",
        )
        need(
            inventory(sample["results"]) == expected, "sample workload catalog differs"
        )
        for row in sample["results"]:
            need(
                number(row["elapsed_ns"], positive=True)
                and number(row["ns_per_op"], positive=True)
                and number(row["allocated_bytes_per_op"]),
                "invalid measurement",
            )
            need(
                math.isclose(
                    row["ns_per_op"] * row["iterations"],
                    row["elapsed_ns"],
                    rel_tol=1e-9,
                ),
                "inconsistent elapsed time",
            )
            need(
                row["warmups"] == min(3, row.get("base_iterations", row["iterations"])),
                "invalid warmup count",
            )
            for key in ("minor_collections", "major_collections"):
                need(type(row[key]) is int and row[key] >= 0, "invalid GC count")
    indexed = [{r["id"]: r for r in s["results"]} for s in samples]
    results = []
    for case, entry in sorted(expected.items()):
        rows = [s[case] for s in indexed]
        times = [r["ns_per_op"] for r in rows]
        median = statistics.median(times)
        duration_met = all(
            r["elapsed_ns"] >= s.get("min_ms", 0) * 1e6 for r, s in zip(rows, samples)
        )
        results.append(
            dict(
                entry,
                median_ns_per_op=median,
                median_bootstrap_95_ns=median_interval(times),
                timing_quality=(
                    "short-batch"
                    if not duration_met
                    else (
                        "noisy"
                        if statistics.stdev(times) / statistics.mean(times) > 0.1
                        else "low-observed-variation"
                    )
                ),
                min_ns_per_op=min(times),
                max_ns_per_op=max(times),
                coefficient_of_variation=statistics.stdev(times)
                / statistics.mean(times),
                median_allocated_bytes_per_op=statistics.median(
                    r["allocated_bytes_per_op"] for r in rows
                ),
                operations_per_second=1e9 / median,
                payload_mib_per_second=(
                    entry["bytes_per_op"] * 1e9 / median / 1048576
                    if entry["bytes_per_op"]
                    else None
                ),
            )
        )
    return results


def validate_report(report):
    """Rebuild retained derived data before rendering or comparing evidence."""
    need(report.get("schema") == SCHEMA, "unsupported report schema")
    validate_exclusions(report.get("exclusions", []), report["catalog"])
    rebuilt = aggregate(
        report["samples"],
        report["catalog"],
        report["compiler"],
        report["config"]["quick"],
    )
    need(report["results"] == rebuilt, "report summary does not match retained samples")
    need(
        len(report["samples"]) == report["config"]["samples"],
        "report sample count differs",
    )
    need(
        all(
            s.get("min_ms", 0) == report["config"].get("min_ms", 0)
            for s in report["samples"]
        ),
        "report calibration differs",
    )
    need(
        [s["seed"] for s in report["samples"]] == report["config"]["seeds"],
        "report seed order differs",
    )
    exclusions = report.get("exclusions", [])
    need(
        all(sample.get("exclusions", []) == exclusions for sample in report["samples"]),
        "sample exclusions differ from report",
    )
    comparisons = library_comparisons(report["results"], report["samples"])
    need(
        report.get("library_comparisons", []) == comparisons,
        "library comparisons do not match retained samples",
    )


def compare(current, baseline):
    # Production source hashes may differ; workload, toolchain and host may not.
    # This compatibility check cannot establish thermal/load isolation.
    for key in (
        "schema",
        "compiler",
        "profile",
        "workload_sha256",
        "host_fingerprint",
        "config",
    ):
        need(current[key] == baseline[key], f"incompatible baseline: {key}")
    for report in (current, baseline):
        validate_report(report)
    need(
        current.get("exclusions", []) == baseline.get("exclusions", []),
        "incompatible baseline: exclusions",
    )
    need(
        inventory(current["catalog"]) == inventory(baseline["catalog"]),
        "incompatible baseline: catalog",
    )
    old = {r["id"]: r for r in baseline["results"]}
    deltas = []
    for row in current["results"]:
        previous = old[row["id"]]
        before = previous["median_allocated_bytes_per_op"]
        delta = row["median_allocated_bytes_per_op"] - before
        deltas.append(
            {
                "id": row["id"],
                "time_change_percent": 100
                * (row["median_ns_per_op"] / previous["median_ns_per_op"] - 1),
                "allocation_change_bytes_per_op": delta,
                "allocation_change_percent": 100 * delta / before if before else None,
            }
        )
    return deltas


def workload_hash():
    digest = hashlib.sha256()
    paths = list((ROOT / "bench").glob("*.ml"))
    paths += [
        ROOT / p
        for p in (
            "bench/dune",
            "tools/benchmarks.py",
            "tools/dune_env.py",
            "dune",
            "dune-project",
            "dune-workspace",
            "toolchain/manifest.json",
        )
    ]
    paths += [p for p in (ROOT / "dune.lock").rglob("*") if p.is_file()]
    for path in sorted(paths):
        digest.update(
            str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes() + b"\0"
        )
    return digest.hexdigest()


def markdown(report):
    lines = [
        "# HTTP toolkit benchmarks",
        "",
        f"{len(report['results'])} cases; {len(report['samples'])} fresh process samples; OCaml {report['compiler']}; release profile.",
        "",
        "Timing verdict: **ADVISORY**. Timed operations include result checks. Throughput uses the byte count documented for each family.",
        "",
        "| Case | Median ns/op | Range ns/op | CV | Alloc B/op | MiB/s |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    if report.get("library_comparisons"):
        intro = [
            "",
            "External libraries: "
            + ", ".join(f"{k} {v}" for k, v in report["libraries"].items())
            + ".",
            "",
            "HTTP heads: raw upstream parsers versus the validating httpkit codec; validation work is not equivalent.",
            "Routes lane: common GET paths only; excludes method policy and conflicting route precedence.",
            "Body lanes: owned scan/collection and borrowed scan are distinct; kit Data is always owned. Includes setup and cleanup.",
            "Exchange lane: public server body writers plus receive/send and persistent pipelines; exact payload/framing oracle.",
            "Router experiments: first-prefix and deep-prefix indexes compared with the reference matcher; neither is shipped.",
            "Times include API adaptation and result checks. No overall winner or security verdict is implied.",
            "Allocation is GC heap only; externally allocated Bigarray payloads are excluded.",
            "",
            "**Time ratio = other / httpkit**, paired within each process. Below 1 means the other library was faster.",
            "",
            "| Family / workload | Other | httpkit ns/op | Other ns/op | Time ratio | httpkit B/op | Other B/op |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
        ]
        for r in report["library_comparisons"]:
            intro.append(
                f"| {r['family']}/{r['workload']} | {r['implementation']} | {r['httpkit_ns_per_op']:.1f} | "
                f"{r['other_ns_per_op']:.1f} | {r['median_other_over_httpkit_time_ratio']:.3f} | "
                f"{r['httpkit_allocated_bytes_per_op']:.1f} | {r['other_allocated_bytes_per_op']:.1f} |"
            )
        lines[5:5] = intro + [""]
    for r in report["results"]:
        throughput = (
            "-"
            if r["payload_mib_per_second"] is None
            else f"{r['payload_mib_per_second']:.2f}"
        )
        lines.append(
            f"| {r['id']} | {r['median_ns_per_op']:.1f} | {r['min_ns_per_op']:.1f}–{r['max_ns_per_op']:.1f} | "
            f"{r['coefficient_of_variation']:.1%} | {r['median_allocated_bytes_per_op']:.1f} | {throughput} |"
        )
    lines += [
        "",
        "## Measurement quality",
        "",
        "Intervals below are descriptive 95% bootstrap intervals of the process-mean median. They are not request latency percentiles.",
        "Do not rank noisy (>10% CV) or short-batch cases. Low observed variation does not establish reserved hardware.",
        "",
        "| Case | Quality | Median interval ns/op |",
        "| --- | --- | ---: |",
    ]
    for row in report["results"]:
        lo, hi = row["median_bootstrap_95_ns"]
        lines.append(f"| {row['id']} | {row['timing_quality']} | {lo:.1f}–{hi:.1f} |")
    if report.get("exclusions"):
        lines += [
            "",
            "## Excluded workloads",
            "",
            "These full comparison groups failed the common framing boundary preflight and have no timing ratio.",
            "",
            "| Workload | Observed implementation | Consumed / wire bytes | Reason |",
            "| --- | --- | ---: | --- |",
        ]
        for group in report["exclusions"]:
            for observation in group["observations"]:
                lines.append(
                    f"| {group['comparison']} | {observation['implementation']} | {observation['consumed_bytes']} / {observation['wire_bytes']} | {observation['reason']} |"
                )
    if "comparison" in report:
        lines += [
            "",
            "Positive changes mean slower execution or more allocation. No regression gate is applied.",
            "",
            "| Case | Time change | Allocation change B/op |",
            "| --- | ---: | ---: |",
        ]
        for r in report["comparison"]:
            lines.append(
                f"| {r['id']} | {r['time_change_percent']:+.1f}% | {r['allocation_change_bytes_per_op']:+.1f} |"
            )
    return "\n".join(lines) + "\n"


def sample_timeout(case_count, min_ms):
    """Bound a whole process including geometric calibration and warmups.

    Up to 25 calibration batches can reach the 10M-iteration cap. Allow setup
    and coarse timer overshoot too; extremely slow operations still time out.
    """
    need(type(case_count) is int and case_count > 0, "invalid selected case count")
    need(number(min_ms) and min_ms <= 1000, "invalid calibration duration")
    seconds = math.ceil(60 + case_count * (0.5 + 32 * min_ms / 1000))
    need(
        seconds <= 12 * 3600,
        "selection exceeds 12-hour sample budget; reduce cases or min-ms",
    )
    return max(600, seconds)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=FAMILIES, default="all")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument(
        "--min-ms",
        type=float,
        default=0,
        help="Calibrate each batch to this minimum duration (0-1000 ms)",
    )
    parser.add_argument(
        "--case",
        default="",
        help="Case id substring; external selection must retain complete comparison groups",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Tenfold fewer iterations; smoke evidence only",
    )
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--baseline", type=Path, help="Compatible retained report.json to compare"
    )
    parser.add_argument(
        "--external",
        action="store_true",
        help="Compare Routes/httpaf/httpun on common workloads",
    )
    args = parser.parse_args()
    if not math.isfinite(args.min_ms) or not 0 <= args.min_ms <= 1000:
        parser.error("--min-ms must be finite and between 0 and 1000")
    if args.quick and args.min_ms:
        parser.error("--quick cannot be combined with calibrated measurements")
    if not 2 <= args.samples <= 50:
        parser.error("--samples must be between 2 and 50")
    if not 0 <= args.seed <= 2147483647 - args.samples:
        parser.error("--seed must fit a positive signed 32-bit seed sequence")
    if args.external and args.family not in (
        "all",
        "router",
        "http1",
        "body",
        "exchange",
        "router-experiment",
    ):
        parser.error(
            "--external supports all, router, http1, body, exchange or router-experiment"
        )
    if not args.external and args.family in ("body", "exchange", "router-experiment"):
        parser.error("body, exchange and router-experiment require --external")
    dune, env, lock = configuration()
    require_lock(lock)
    # Clear instrumentation and runtime tuning inherited from fuzz/coverage or a
    # developer's shell. Never reuse their build directory for timing samples.
    cleared = []
    for key in list(env):
        if key.startswith(("BISECT_", "AFL_")) or key in (
            "OCAMLPARAM",
            "OCAMLRUNPARAM",
            "CAMLRUNPARAM",
            "DUNE_INSTRUMENT_WITH",
        ):
            cleared.append(key)
            env.pop(key)
    compiler = env["HARNESS_COMPILER"]
    build_dir = "_build-bench-" + compiler
    digest, workload = source_hash(), workload_hash()
    subprocess.run(
        command(
            dune,
            env,
            [
                "build",
                "--profile=release",
                "--build-dir=" + build_dir,
                "bench/suite_bench.exe",
            ],
        ),
        cwd=ROOT,
        env=env,
        check=True,
        timeout=1800,
    )
    binary = ROOT / build_dir / "default/bench/suite_bench.exe"
    flags = [
        "--family",
        args.family,
        "--min-ms",
        str(args.min_ms),
        "--case",
        args.case,
    ] + (["--quick"] if args.quick else [])
    if args.external:
        flags.append("--external")
    catalog_sample = json.loads(
        subprocess.check_output(
            [str(binary), *flags, "--preflight-only"], env=env, text=True, timeout=60
        )
    )
    need(catalog_sample["compiler"] == compiler, "wrong benchmark compiler")
    catalog = catalog_sample["results"]
    inventory(catalog)
    if args.external:
        groups = {}
        for row in catalog:
            groups.setdefault((row["family"], row["comparison"]), set()).add(
                row["implementation"]
            )
        need(
            all(
                implementations == EXTERNAL_IMPLEMENTATIONS[family]
                for (family, _), implementations in groups.items()
            ),
            "case selection must retain complete comparison groups",
        )
    validate_exclusions(catalog_sample.get("exclusions", []), catalog)
    timeout = sample_timeout(len(catalog), args.min_ms)
    print(f"Selected {len(catalog)} cases; per-process timeout {timeout}s", flush=True)
    parent = ROOT / "_artifacts/benchmarks"
    parent.mkdir(parents=True, exist_ok=True)
    directory = Path(
        tempfile.mkdtemp(
            prefix=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-"), dir=parent
        )
    )
    samples = []
    seeds = list(range(args.seed, args.seed + args.samples))
    load_observations = []
    for index, seed in enumerate(seeds):
        load_before = os.getloadavg() if hasattr(os, "getloadavg") else None
        raw = subprocess.check_output(
            [str(binary), *flags, "--seed", str(seed)],
            env=env,
            text=True,
            timeout=timeout,
        )
        load_observations.append(
            dict(
                seed=seed,
                before=load_before,
                after=os.getloadavg() if hasattr(os, "getloadavg") else None,
            )
        )
        (directory / f"sample-{index + 1}.json").write_text(raw)
        samples.append(json.loads(raw))
        need(samples[-1].get("min_ms", 0) == args.min_ms, "calibration settings differ")
        need(
            samples[-1].get("exclusions", []) == catalog_sample.get("exclusions", []),
            "preflight exclusions differ across samples",
        )
        print(
            f'Sample {index + 1}/{args.samples}: {len(samples[-1]["results"])} cases',
            flush=True,
        )
    need(source_hash() == digest, "sources changed during benchmark run")
    host = dict(
        system=platform.system(),
        release=platform.release(),
        machine=platform.machine(),
        processor=platform.processor(),
        cpu_count=os.cpu_count(),
    )
    fingerprint = hashlib.sha256(
        (platform.node() + json.dumps(host, sort_keys=True)).encode()
    ).hexdigest()
    report = dict(
        schema=SCHEMA,
        status="PASS",
        timing_verdict="ADVISORY",
        compiler=compiler,
        profile="release",
        source_sha256=digest,
        workload_sha256=workload,
        host=host,
        host_fingerprint=fingerprint,
        exclusions=catalog_sample.get("exclusions", []),
        cleared_environment=sorted(cleared),
        load_observations=load_observations,
        catalog=catalog,
        samples=samples,
        config=dict(
            family=args.family,
            quick=args.quick,
            samples=args.samples,
            seeds=seeds,
            external=args.external,
            min_ms=args.min_ms,
            case=args.case,
        ),
        results=aggregate(samples, catalog, compiler, args.quick),
        limitations=[
            "Timed operations include correctness checks and loop overhead.",
            "Sample means are not request latency percentiles.",
            "Host identity does not establish reserved hardware, stable power or load.",
            "These measurements do not approve M7 performance or security gates.",
        ],
    )
    if args.external:
        report["libraries"] = locked_comparison_versions(lock)
        report["library_comparisons"] = library_comparisons(report["results"], samples)
        need(report["library_comparisons"], "missing external comparisons")
        report["limitations"] += [
            "Upstream private head parsers do less validation than httpkit; parsing responsibilities differ.",
            "Routing excludes method policy and ambiguous precedence; Routes wildcard slash normalization is timed.",
            "GC allocation excludes external Bigarray payloads and does not measure total memory.",
            "Unique header names only; the httpaf raw-parser reversed field representation is checked explicitly.",
        ]
    validate_report(report)
    if args.baseline:
        report["comparison"] = compare(report, json.loads(args.baseline.read_text()))
        report["baseline"] = str(args.baseline.resolve())
    (directory / "report.json").write_text(
        json.dumps(report, indent=2, allow_nan=False) + "\n"
    )
    (directory / "report.md").write_text(markdown(report))
    noisy = sum(r["coefficient_of_variation"] > 0.1 for r in report["results"])
    print(
        f'PASS: {len(report["results"])} cases; {noisy} with CV > 10%; timing ADVISORY\n{directory / "report.md"}\n{directory / "report.json"}'
    )


if __name__ == "__main__":
    main()
