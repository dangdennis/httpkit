#!/usr/bin/env python3
"""Source-matched Eio framework profiles and sustained acceptance workloads."""

import argparse
from contextlib import ExitStack
from test_framework_databases import Postgres
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
import random
import signal
import socket
import struct
import subprocess
import threading
import time
from checks import require
from dune_env import ROOT, configuration, command
from evidence import source_hash
from personal_use import descriptors, check_resources, BUCKETS
from test_framework import Application, exercise, frame, recv_exact, recv_frame


def operation(app, c, mode):
    if mode == 1 and app.database_uri is not None:
        status, _, data = app.request("GET", "/db", connection=c)
        require(status == 200 and data == b"1", "database result")
        return "database", len(data)
    if mode in (0, 1):
        status, _, data = app.request("GET", "/health", connection=c)
        require(status == 200 and data == b"ok\n", "health bytes")
        return "health", len(data)
    if mode == 2:
        payload = b'{"message":"' + b"x" * 4096 + b'"}'
        status, _, data = app.request(
            "POST", "/json", payload, {"Content-Type": "application/json"}, connection=c
        )
        require(status == 200 and data == payload, "JSON bytes")
        return "json", len(data) + len(payload)
    if mode == 3:
        payload = (
            b'--x\r\nContent-Disposition: form-data; name="file"; filename="test.bin"\r\n\r\n'
            + b"x" * 16384
            + b"\r\n--x--\r\n"
        )
        status, _, data = app.request(
            "POST",
            "/upload",
            payload,
            {"Content-Type": "multipart/form-data; boundary=x"},
            connection=c,
        )
        require(status == 200 and data == b"16384", "multipart bytes")
        return "multipart", len(payload)
    if mode in (4, 5):
        c.request("GET", "/stream")
        r = c.getresponse()
        require(r.status == 200, "stream status")
        total = 0
        while data := r.read(8192):
            require(data == b"x" * len(data), "stream corruption")
            total += len(data)
            if mode == 5:
                time.sleep(0.001)
        require(total == 1048576, "stream length")
        return ("slow-stream" if mode == 5 else "stream"), total
    if mode == 6:
        status, headers, _ = app.request(
            "POST",
            "/login",
            headers={"Authorization": "Bearer synthetic-test-token"},
            connection=c,
        )
        require(status == 200, "login")
        cookie = headers["set-cookie"].split(";")[0]
        status, _, data = app.request(
            "GET", "/session", headers={"Cookie": cookie}, connection=c
        )
        require(status == 200, "session")
        token = json.loads(data)["csrf"]
        status, _, _ = app.request(
            "POST",
            "/logout",
            headers={
                "Cookie": cookie,
                "Origin": "https://app.example",
                "X-CSRF-Token": token,
            },
            connection=c,
        )
        require(status == 200, "logout")
        return "session-cycle", len(data)
    if mode == 7:
        status, _, data = app.request("GET", "/events", connection=c)
        require(status == 200 and data.count(b"data: event ") == 3, "SSE")
        return "sse", len(data)
    if mode == 8:
        with socket.create_connection(("127.0.0.1", app.port), timeout=10) as s:
            s.sendall(b"GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
            require(s.recv(64).startswith(b"HTTP/1.1 200"), "reset stream start")
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        return "reset-stream", 0
    with socket.create_connection(("127.0.0.1", app.port), timeout=10) as s:
        s.sendall(
            b"GET /ws HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\nOrigin: https://app.example\r\n\r\n"
            + frame(1, b"hello")
        )
        response = b""
        while not response.endswith(b"\r\n\r\n"):
            response += recv_exact(s, 1)
        require(response.startswith(b"HTTP/1.1 101"), "upgrade")
        require(recv_frame(s) == (1, b"hello"), "WebSocket echo")
        s.sendall(frame(8))
        require(recv_frame(s) == (8, b""), "WebSocket close")
    return "websocket", 5


def epoch(app, seconds, concurrency, rate, seed):
    start = time.monotonic()
    deadline = start + seconds
    stop = threading.Event()

    def worker(index):
        rng = random.Random(seed + index)
        counts = {}
        hist = {}
        payload = 0
        c = app.connect()
        try:
            while time.monotonic() < deadline and not stop.is_set():
                begin = time.monotonic()
                name, size = operation(app, c, rng.randrange(10))
                elapsed = time.monotonic() - begin
                bucket = next(
                    (i for i, upper in enumerate(BUCKETS) if elapsed * 1000 <= upper),
                    None,
                )
                require(bucket is not None, ("operation over 10 seconds", name))
                counts[name] = counts.get(name, 0) + 1
                payload += size
                hist.setdefault(name, [0] * len(BUCKETS))[bucket] += 1
                if rate:
                    stop.wait(max(0, concurrency / rate - elapsed))
        except BaseException:
            stop.set()
            raise
        finally:
            c.close()
        return counts, hist, payload

    pool = ThreadPoolExecutor(max_workers=concurrency)
    try:
        rows = list(pool.map(worker, range(concurrency)))
    finally:
        stop.set()
        pool.shutdown(wait=True, cancel_futures=True)
    counts = {}
    hist = {}
    payload = 0
    for cs, hs, n in rows:
        payload += n
        for k, v in cs.items():
            counts[k] = counts.get(k, 0) + v
        for k, v in hs.items():
            hist[k] = [a + b for a, b in zip(hist.get(k, [0] * len(BUCKETS)), v)]
    operations = sum(counts.values())
    elapsed = time.monotonic() - start
    require(operations > 0, "empty epoch")
    if rate and seconds >= 30:
        require(operations >= seconds * rate * 0.25, "insufficient sustained activity")
    return dict(
        seconds=elapsed,
        operations=operations,
        operations_per_second=operations / elapsed,
        concurrency=concurrency,
        counts=counts,
        payload_bytes=payload,
        latency_upper_ms=BUCKETS,
        latency_counts_by_workload=hist,
    )


class PersistentConnection:
    def __init__(self, app):
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.errors = []
        self.requests = 0

        def run():
            c = app.connect()
            identity = None
            try:
                while not self.stop.is_set():
                    status, _, data = app.request("GET", "/health", connection=c)
                    require(status == 200 and data == b"ok\n", "persistent response")
                    require(c.sock is not None, "persistent socket missing")
                    if identity is None:
                        identity = c.sock
                    require(c.sock is identity, "persistent connection replaced")
                    self.requests += 1
                    self.ready.set()
                    self.stop.wait(5)
            except BaseException as error:
                self.errors.append(repr(error))
                self.ready.set()
            finally:
                c.close()

        self.thread = threading.Thread(target=run)
        self.thread.start()
        if not self.ready.wait(15) or self.errors:
            self.close()
            raise RuntimeError("persistent start timeout")

    def close(self):
        self.stop.set()
        self.thread.join(timeout=20)
        require(
            not self.thread.is_alive() and not self.errors,
            ("persistent connection failure", self.errors),
        )


def observe(app, persistent):
    deadline = time.monotonic() + 5
    while True:
        status, _, body = app.request("GET", "/stats")
        require(status == 200, "resource endpoint")
        row = json.loads(body)
        if row["active"] == 1 + int(persistent):
            break
        require(time.monotonic() < deadline, ("unclosed transports", row))
        time.sleep(0.02)
    require(
        row["unexpected_errors"] == 0 and row["peak_active"] <= 16,
        ("application error or admission limit", row),
    )
    row["rss_kib"] = int(
        subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(app.process.pid)], text=True, timeout=5
        )
    )
    row["descriptors"] = descriptors(app.process.pid)
    return row


def graceful(app):
    partial = socket.create_connection(("127.0.0.1", app.port), timeout=15)
    c = app.connect()
    try:
        partial.sendall(
            b"POST /json HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{"
        )
        c.request("GET", "/stream")
        response = c.getresponse()
        require(response.status == 200, "shutdown stream")
        first = response.read(8192)
        require(first == b"x" * 8192, "shutdown prefix")
        total = len(first)
        start = time.monotonic()
        app.process.send_signal(signal.SIGTERM)
        while data := response.read(8192):
            require(data == b"x" * len(data), "shutdown stream corruption")
            total += len(data)
            time.sleep(0.001)
        require(total == 1048576, "shutdown stream truncated")
        app.close()
        require(
            app.final
            and app.final["active"] == 0
            and app.final["opened"] == app.final["closed"]
            and app.final["unexpected_errors"] == 0,
            ("shutdown accounting", app.final),
        )
        return dict(seconds=time.monotonic() - start, final=app.final)
    finally:
        partial.close()
        c.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode", choices=["smoke", "profile", "canary", "soak"], default="smoke"
    )
    parser.add_argument("--seconds", type=float)
    parser.add_argument("--binary")
    parser.add_argument(
        "--database", choices=["none", "sqlite", "postgresql"], default="none"
    )
    args = parser.parse_args()
    if args.binary is None:
        dune, build_env, _ = configuration()
        subprocess.run(
            command(dune, build_env, ["build", "examples/framework/server.exe"]),
            cwd=ROOT,
            env=build_env,
            check=True,
            timeout=1800,
        )
        args.binary = "_build-pkg-5.5.0/default/examples/framework/server.exe"
    seconds = (
        args.seconds
        if args.seconds is not None
        else dict(smoke=3, profile=10, canary=1800, soak=7200)[args.mode]
    )
    require(math.isfinite(seconds) and seconds > 0, "positive finite duration")
    digest = source_hash()
    directory = ROOT / "_artifacts/framework" / f"{args.mode}-{time.time_ns()}"
    directory.mkdir(parents=True)
    report = dict(
        status="RUNNING",
        mode=args.mode,
        database=args.database,
        seconds_requested=seconds,
        source_sha256=digest,
        binary_sha256=hashlib.sha256((ROOT / args.binary).read_bytes()).hexdigest(),
        epochs=[],
        observations=[],
    )
    report_path = directory / "report.json"

    def save():
        report_path.write_text(json.dumps(report, indent=2) + "\n")

    resources = ExitStack()
    app = None
    persistent = None
    try:
        database_uri = None
        if args.database == "sqlite":
            database_uri = "sqlite3:" + str(directory / "load.sqlite")
        elif args.database == "postgresql":
            database_uri = resources.enter_context(Postgres(directory / "postgres"))
        app = Application(args.binary, directory, database_uri=database_uri)
        exercise(app)
        long = args.mode in ("canary", "soak")
        if long:
            persistent = PersistentConnection(app)
        report["observations"].append(observe(app, long))
        save()
        durations = (
            [(seconds, c) for c in (1, 4, 8)]
            if args.mode == "profile"
            else [(min(60, seconds - i), 4) for i in range(0, math.ceil(seconds), 60)]
        )
        for index, (duration, concurrency) in enumerate(durations):
            require(source_hash() == digest, "source changed during load")
            report["epochs"].append(
                epoch(
                    app, duration, concurrency, 20 if long else None, 912 + index * 100
                )
            )
            report["observations"].append(observe(app, long))
            # The extra long-lived connection is expected and reported explicitly.
            check_resources(
                [
                    dict(row, active=row["active"] - int(long))
                    for row in report["observations"]
                ]
            )
            if persistent:
                require(not persistent.errors, persistent.errors)
            save()
        if persistent:
            persistent.close()
            report["persistent_connection_requests"] = persistent.requests
            persistent = None
        report["shutdown"] = graceful(app)
        app = None
        require(source_hash() == digest, "source changed during final checks")
        resources.close()
        report["status"] = "PASS"
        save()
        (ROOT / "_artifacts/framework" / f"{args.mode}.json").write_text(
            json.dumps(report, indent=2) + "\n"
        )
        print(
            json.dumps(
                dict(
                    status="PASS",
                    mode=args.mode,
                    database=args.database,
                    operations=sum(e["operations"] for e in report["epochs"]),
                    report=str(report_path),
                )
            )
        )
    except BaseException as error:
        report["status"] = (
            "INTERRUPTED" if isinstance(error, KeyboardInterrupt) else "FAIL"
        )
        report["error"] = repr(error)
        save()
        raise
    finally:
        try:
            if persistent:
                persistent.close()
        finally:
            try:
                if app is not None:
                    app.close()
            finally:
                resources.close()


if __name__ == "__main__":
    main()
