#!/usr/bin/env python3
"""Real HTTP/Eio integration controls; all credentials and files are synthetic."""

import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import time
from checks import require
from dune_env import configuration, command

ROOT = Path(__file__).resolve().parent.parent


def frame(op, data=b"", fin=True):
    mask = b"1234"
    n = len(data)
    head = bytes([(128 if fin else 0) | op])
    if n < 126:
        head += bytes([128 | n])
    elif n < 65536:
        head += bytes([254]) + struct.pack("!H", n)
    else:
        head += bytes([255]) + struct.pack("!Q", n)
    return head + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data))


def recv_exact(sock, n):
    result = b""
    while len(result) < n:
        chunk = sock.recv(n - len(result))
        require(chunk, "unexpected EOF")
        result += chunk
    return result


def recv_frame(sock):
    a, b = recv_exact(sock, 2)
    require(a & 128 and not b & 128, "server frame flags")
    n = b & 127
    if n == 126:
        n = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack("!Q", recv_exact(sock, 8))[0]
    require(n <= 2**20, "response frame bound")
    return a & 15, recv_exact(sock, n)


class Application:
    def __init__(self, binary, directory, database_uri=None):
        self.directory = Path(directory)
        public = self.directory / "public"
        public.mkdir()
        (public / "hello.txt").write_text("static contents\n")
        (self.directory / "private.txt").write_text("PRIVATE SENTINEL")
        (public / "escape.txt").symlink_to(self.directory / "private.txt")
        self.log = (self.directory / "server.log").open("w")
        env = dict(
            os.environ,
            PORT="0",
            APP_ORIGIN="https://app.example",
            STATIC_ROOT=str(public),
            DEMO_LOGIN_TOKEN="synthetic-test-token",
            FRAMEWORK_TEST_MODE="1",
        )
        env = {k: v for k, v in env.items() if not k.startswith("PG")}
        env.pop("DATABASE_URL", None)
        if database_uri is not None:
            env["DATABASE_URL"] = database_uri
        self.database_uri = database_uri
        self.closed = False
        self.final = None
        try:
            self.process = subprocess.Popen(
                [str(Path(binary).resolve())],
                cwd=ROOT,
                env=env,
                stdout=subprocess.PIPE,
                stderr=self.log,
                text=True,
                start_new_session=True,
            )
        except BaseException:
            self.log.close()
            raise
        import select

        try:
            require(
                select.select([self.process.stdout], [], [], 30)[0],
                "server start timeout",
            )
            line = self.process.stdout.readline().strip()
            require(line.startswith("LISTEN "), ("server start", line))
            self.port = int(line.split()[1])
        except BaseException:
            self.process.kill()
            self.process.wait()
            self.process.stdout.close()
            self.log.close()
            raise

    def connect(self):
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)

    def request(self, method, path, body=None, headers=None, connection=None):
        own = connection is None
        c = self.connect() if own else connection
        try:
            c.request(method, path, body=body, headers=headers or {})
            r = c.getresponse()
            data = r.read()
            return r.status, dict(r.getheaders()), data
        finally:
            if own:
                c.close()

    def close(self):
        if self.closed:
            return
        try:
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGTERM)
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
                    raise
            remaining = self.process.stdout.read()
            self.final = (
                json.loads(remaining.strip().splitlines()[-1])
                if remaining.strip()
                else None
            )
        finally:
            self.closed = True
            self.process.stdout.close()
            self.log.close()
        require(
            self.process.returncode == 0, ("server shutdown", self.process.returncode)
        )


def exercise(app):
    ids = set()
    c = app.connect()
    try:
        for _ in range(10):
            status, headers, body = app.request("GET", "/health", connection=c)
            require(status == 200 and body == b"ok\n", "health")
            require(headers["x-content-type-options"] == "nosniff", "security headers")
            ids.add(headers["x-request-id"])
        require(len(ids) == 10, "fresh request IDs")
        status, headers, body = app.request("HEAD", "/health", connection=c)
        require(
            status == 200 and body == b"" and headers["content-length"] == "3",
            "HEAD fallback",
        )
        require(
            app.request("POST", "/health", connection=c)[0] == 405, "method handling"
        )
        require(app.request("GET", "/missing", connection=c)[0] == 404, "not found")
        require(
            app.request("GET", "/error", connection=c)[0] == 500, "exception recovery"
        )
        require(
            app.request("GET", "/health", connection=c)[0] == 200,
            "connection after recovery",
        )
    finally:
        c.close()
    h = {"Content-Type": "application/json"}
    require(app.request("POST", "/json", b'{"x":1}', h)[2] == b'{"x":1}', "JSON echo")
    for payload in [b'{"x":1,"x":2}', b"[[[" + b"[" * 100 + b"0" + b"]" * 103, b"{"]:
        require(
            app.request("POST", "/json", payload, h)[0] == 400, "JSON malformed/depth"
        )
    require(
        app.request(
            "POST",
            "/form",
            b"x=a%26b",
            {"Content-Type": "application/x-www-form-urlencoded"},
        )[2]
        == b'{"x":"a&b"}',
        "form decoding",
    )
    multipart = b'--x\r\nContent-Disposition: form-data; name="file"; filename="../../evil"\r\n\r\nhello\r\n--x--\r\n'
    require(
        app.request(
            "POST",
            "/upload",
            multipart,
            {"Content-Type": "multipart/form-data; boundary=x"},
        )[2]
        == b"5",
        "multipart upload",
    )
    status, headers, data = app.request("GET", "/static/hello.txt")
    require(status == 200 and data == b"static contents\n", "static file")
    require(
        app.request(
            "GET", "/static/hello.txt", headers={"If-None-Match": headers["etag"]}
        )[0]
        == 304,
        "static validator",
    )
    for path in [
        "/static/%2e%2e/private.txt",
        "/static/escape.txt",
        "/static/.env",
        "/static/%2fetc/passwd",
    ]:
        status, _, data = app.request("GET", path)
        require(
            status in [400, 404] and b"PRIVATE" not in data,
            ("static confinement", path),
        )
    require(app.request("GET", "/stream")[2] == b"x" * 1048576, "bounded stream bytes")
    require(app.request("HEAD", "/stream")[2] == b"", "HEAD skips producer")
    require(
        app.request("GET", "/events")[2]
        == b"id: 1\ndata: event 1\n\nid: 2\ndata: event 2\n\nid: 3\ndata: event 3\n\n",
        "SSE bytes",
    )
    status, headers, _ = app.request(
        "OPTIONS",
        "/json",
        headers={
            "Origin": "https://app.example",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )
    require(
        status == 204
        and headers["access-control-allow-origin"] == "https://app.example",
        "CORS preflight",
    )
    require(
        app.request("GET", "/health", headers={"Origin": "https://evil.example"})[0]
        == 403,
        "CORS denied",
    )
    require(app.request("POST", "/login")[0] == 401, "no default authentication")
    status, headers, _ = app.request(
        "POST", "/login", headers={"Authorization": "Bearer synthetic-test-token"}
    )
    require(
        status == 200
        and "Secure" in headers["set-cookie"]
        and "HttpOnly" in headers["set-cookie"],
        "session cookie",
    )
    cookie = headers["set-cookie"].split(";")[0]
    status, _, data = app.request("GET", "/session", headers={"Cookie": cookie})
    require(status == 200, "session lookup")
    csrf = json.loads(data)["csrf"]
    require(
        app.request("GET", "/session", headers={"Cookie": cookie + "; " + cookie})[0]
        == 401,
        "ambiguous session",
    )
    require(
        app.request(
            "POST",
            "/logout",
            headers={"Cookie": cookie, "Origin": "https://app.example"},
        )[0]
        == 403,
        "CSRF required",
    )
    require(
        app.request(
            "POST",
            "/logout",
            headers={
                "Cookie": cookie,
                "Origin": "https://app.example",
                "X-CSRF-Token": csrf,
            },
        )[0]
        == 200,
        "logout",
    )
    require(
        app.request("GET", "/session", headers={"Cookie": cookie})[0] == 401,
        "revocation",
    )
    # Handshake and first frame coalesce; residual bytes must survive handoff.
    sock = socket.create_connection(("127.0.0.1", app.port), timeout=10)
    with sock:
        key = base64.b64encode(b"0123456789abcdef").decode()
        head = (
            f"GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\nOrigin: https://app.example\r\n\r\n"
        ).encode()
        sock.sendall(head + frame(1, b"hello"))
        response = b""
        while not response.endswith(b"\r\n\r\n"):
            response += recv_exact(sock, 1)
        require(response.startswith(b"HTTP/1.1 101"), "WebSocket upgrade")
        expected = base64.b64encode(
            hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()
        )
        require(expected in response, "WebSocket accept vector")
        require(recv_frame(sock) == (1, b"hello"), "handoff suffix")
        for part in (
            frame(1, b"fragment ", False) + frame(9, b"p") + frame(0, b"complete")
        ):
            sock.sendall(bytes([part]))
        require(recv_frame(sock) == (10, b"p"), "WebSocket pong")
        require(
            recv_frame(sock) == (1, b"fragment complete"), "WebSocket fragmentation"
        )
        sock.sendall(frame(8))
        require(recv_frame(sock) == (8, b""), "WebSocket close")
    # An Expect client rejected before body consumption must not wait for 100.
    with socket.create_connection(("127.0.0.1", app.port), timeout=10) as s:
        s.sendall(
            b"POST /missing HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 100\r\n\r\n"
        )
        require(s.recv(4096).startswith(b"HTTP/1.1 404"), "early rejection")
    print(
        "PASS framework HTTP, sessions/CSRF, static confinement, streaming, SSE and WebSocket lifecycle"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary")
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

    directory = ROOT / "_artifacts/framework" / f"integration-{time.time_ns()}"
    directory.mkdir(parents=True)
    app = Application(args.binary, directory)
    try:
        exercise(app)
    finally:
        app.close()


if __name__ == "__main__":
    main()
