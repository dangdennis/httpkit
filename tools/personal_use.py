#!/usr/bin/env python3
"""Eio application checks, local load profile and sustained mixed-load evidence.

All traffic stays on loopback. The workload retains bounded histograms, uploads
and download chunks; server observations are taken only between load epochs.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import http.client
import json
import math
from pathlib import Path
import random
import selectors
import socket
import statistics
import struct
import subprocess
import time

from checks import require
from dune_env import ROOT, configuration, command
from evidence import source_hash, record

DOWNLOAD = 2097152
LIMIT = 1048576
BUCKETS = [.1, .2, .5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]


@contextmanager
def server(binary, directory):
    with (directory / 'server-errors.log').open('wb') as errors:
        p = subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=errors)
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(p.stdout, selectors.EVENT_READ)
                require(ready.select(10), 'server startup timeout')
            line = p.stdout.readline().strip()
            require(line.isdigit(), ('server did not publish port', line))
            yield int(line), p
        finally:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()


def request(port, method, path, body=None, chunked=False, slow=False, connection=None):
    c = connection or http.client.HTTPConnection('127.0.0.1', port, timeout=10)
    try:
        c.request(method, path, body=body, encode_chunked=chunked)
        r = c.getresponse()
        require(r.getheader('x-example') == 'personal-eio', 'middleware missing')
        if path == '/download' and method == 'GET':
            require(r.status == 200, ('download status', r.status))
            size = 0
            while data := r.read(8192):
                require(data == b'x' * len(data), 'download corruption')
                size += len(data)
                require(size <= DOWNLOAD, 'excess download output')
                if slow:
                    time.sleep(.001)
            require(size == DOWNLOAD, ('truncated download', size))
            return r.status, b'', size
        payload = r.read(4096)
        require(not r.read(1), 'unexpected large response')
        return r.status, payload, len(payload)
    finally:
        if connection is None:
            c.close()


def raw(port, wire, half_close=False):
    with socket.create_connection(('127.0.0.1', port), timeout=5) as s:
        try:
            s.sendall(wire)
        except (ConnectionResetError, BrokenPipeError):
            pass
        if half_close:
            try:
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        out = bytearray()
        while True:
            try:
                data = s.recv(4096)
            except ConnectionResetError:
                break
            if not data:
                break
            out.extend(data)
            require(len(out) <= 8192, 'unexpected raw output')
        return bytes(out)


def stats(port):
    status, payload, _ = request(port, 'GET', '/stats')
    require(status == 200, 'stats status')
    return json.loads(payload)


def balanced(port):
    # A client close precedes server cleanup; wait for the observable condition.
    deadline = time.monotonic() + 10
    while True:
        row = stats(port)
        if row['active'] == 1:
            require(row['opened'] == row['closed'] + 1, 'ownership count mismatch')
            require(row['unexpected_errors'] == 0, ('unexpected errors', row))
            require(row['peak_active'] <= 16, ('admission overflow', row))
            return row
        require(time.monotonic() < deadline, ('connections did not clean up', row))
        time.sleep(.02)


def descriptors(pid):
    proc = Path(f'/proc/{pid}/fd')
    if proc.is_dir():
        return len(list(proc.iterdir()))
    p = subprocess.run(['lsof', '-a', '-p', str(pid), '-Ff'], capture_output=True,
                       text=True, timeout=10)
    require(p.returncode == 0, ('cannot observe descriptors', p.stderr))
    return sum(line[1:].isdigit() for line in p.stdout.splitlines() if line.startswith('f'))


def resources(port, pid):
    row = balanced(port)
    row['rss_kib'] = int(subprocess.check_output(
        ['ps', '-o', 'rss=', '-p', str(pid)], text=True, timeout=5).strip())
    row['descriptors'] = descriptors(pid)
    return row


def adversarial(port):
    cases = 0
    for method, path, status in [('GET', '/health', 200), ('GET', '/missing', 404),
                                 ('PUT', '/health', 405), ('HEAD', '/health', 405)]:
        actual, _, _ = request(port, method, path)
        require(actual == status, ('route outcome', method, path, actual))
        cases += 1
    body = bytes(range(256)) * 4096
    for chunked in [False, True]:
        outgoing = (body[i:i+173] for i in range(0, len(body), 173)) if chunked else body
        status, payload, _ = request(port, 'POST', '/upload', outgoing, chunked)
        require(status == 200 and payload == f'{len(body)} {sum(body) % 65536}\n'.encode(), 'upload boundary')
        cases += 1
    head = b'POST /upload HTTP/1.1\r\nHost: x\r\n'
    marker = b'GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'
    for fields, payload in [
        (b'Content-Length: 1\r\nTransfer-Encoding: chunked\r\n', b'0\r\n\r\n'),
        (b'Content-Length: 0\r\nContent-Length: 1\r\n', b'x'),
        (b'Content-Length: 1048577\r\n', b''),
        (b'Transfer-Encoding: chunked\r\n', b'wat\r\n'),
    ]:
        before = balanced(port)['requests']
        out = raw(port, head + fields + b'\r\n' + payload + marker, half_close=True)
        require(b'ok\n' not in out and b'200 ' not in out, ('ambiguous input answered', out))
        after = balanced(port)['requests']
        # /stats itself is a request. At most the malformed chunked head can be dispatched.
        require(after - before <= 2, ('marker dispatched', before, after))
        cases += 1
    # The application quota must reject an actual over-limit body, not only a
    # declared length whose payload never arrives. Exercise both framing modes.
    excess = b'x' * (LIMIT + 1)
    for wire in [head + b'Content-Length: 1048577\r\n\r\n' + excess,
                 head + b'Transfer-Encoding: chunked\r\n\r\n100001\r\n' + excess + b'\r\n0\r\n\r\n']:
        out = raw(port, wire, half_close=True)
        require(b'200 ' not in out, 'application upload quota bypassed')
        cases += 1
    # Early rejection must not wait for an Expect client to send its body.
    out = raw(port, b'POST /missing HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 9\r\n\r\n')
    require(b'404 ' in out and b'100 ' not in out, ('early rejection', out))
    cases += 1
    # A valid half-close must still deliver the complete response.
    out = raw(port, marker, half_close=True)
    require(out.endswith(b'ok\n') and out.count(b'HTTP/1.1') == 1, ('half close', out))
    cases += 1
    # Incomplete uploads must never become successful application responses.
    for wire in [head + b'Content-Length: 5\r\n\r\nx',
                 head + b'Transfer-Encoding: chunked\r\n\r\n5\r\nx']:
        out = raw(port, wire, half_close=True)
        require(b'200 ' not in out, ('truncated upload accepted', out))
        cases += 1
    balanced(port)
    return cases


def disconnect(port, download=False):
    with socket.create_connection(('127.0.0.1', port), timeout=5) as s:
        if download:
            s.sendall(b'GET /download HTTP/1.1\r\nHost: x\r\n\r\n')
            require(s.recv(64).startswith(b'HTTP/1.1 200'), 'reset download did not start')
        else:
            s.sendall(b'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 1048576\r\n\r\nx')
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))


def epoch(port, seconds, concurrency, rate, seed):
    deadline = time.monotonic() + seconds
    def worker(index):
        rng = random.Random(seed + index)
        counts = {}; histogram = [0] * len(BUCKETS); by_mode = {}; transferred = 0
        c = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
        try:
            while time.monotonic() < deadline:
                start = time.monotonic()
                mode = rng.randrange(11)
                if mode in [8, 9]:
                    name = 'reset-download' if mode == 9 else 'reset-upload'
                    disconnect(port, download=mode == 9)
                elif mode in [5, 6]:
                    name = 'slow-download' if mode == 6 else 'download'
                    _, _, size = request(port, 'GET', '/download', slow=mode == 6, connection=c)
                    transferred += size
                elif mode in [2, 3, 4, 10]:
                    name = 'slow-upload' if mode == 10 else ('chunked-upload' if mode == 4 else 'fixed-upload')
                    size = rng.choice([0, 17, 4096, 262144])
                    body = bytes([rng.randrange(256)]) * size
                    def chunks():
                        for i in range(0,size,8192):
                            if mode == 10: time.sleep(.001)
                            yield body[i:i+8192]
                    outgoing = chunks() if mode in [4,10] else body
                    status, payload, _ = request(port, 'POST', '/upload', outgoing, mode in [4,10], connection=c)
                    require(status == 200 and payload == f'{size} {sum(body) % 65536}\n'.encode(), 'upload corruption')
                    transferred += size
                else:
                    name = 'health'
                    status, payload, _ = request(port, 'GET', '/health', connection=c)
                    require(status == 200 and payload == b'ok\n', 'health corruption')
                elapsed = time.monotonic() - start
                counts[name] = counts.get(name, 0) + 1
                ms = elapsed * 1000
                bucket = next((i for i, upper in enumerate(BUCKETS) if ms <= upper), None)
                require(bucket is not None, ('operation exceeded 10 seconds', name, ms))
                histogram[bucket] += 1
                by_mode.setdefault(name, [0] * len(BUCKETS))[bucket] += 1
                if rate:
                    time.sleep(max(0, concurrency / rate - elapsed))
        finally:
            c.close()
        return counts, histogram, transferred, by_mode
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        rows = list(pool.map(worker, range(concurrency)))
    elapsed = time.monotonic() - start
    counts = {}; histogram = [0]*len(BUCKETS); by_mode = {}; transferred = 0
    for cs, hs, size, modes in rows:
        for name, buckets in modes.items():
            existing = by_mode.setdefault(name, [0] * len(BUCKETS))
            by_mode[name] = [a+b for a,b in zip(existing,buckets)]
        for name, count in cs.items(): counts[name] = counts.get(name, 0) + count
        histogram = [a+b for a,b in zip(histogram, hs)]
        transferred += size
    total = sum(counts.values())
    require(total > 0, 'empty load epoch')
    if rate and seconds >= 30:
        require(total >= seconds * rate * .25, ('insufficient sustained activity', total, seconds, rate))
    def percentile(p):
        cumulative = 0
        for upper, count in zip(BUCKETS, histogram):
            cumulative += count
            if cumulative >= math.ceil(total*p): return upper
    return dict(seconds=elapsed, concurrency=concurrency, offered_operations_per_second=rate or None,
                operations=total, counts=counts, payload_bytes=transferred,
                operations_per_second=total/elapsed, latency_bucket_upper_ms=BUCKETS,
                latency_counts=histogram, latency_counts_by_workload=by_mode, p50_upper_ms=percentile(.5), p99_upper_ms=percentile(.99))


def check_resources(rows):
    # Conservative personal-use envelopes, not measurements of total engine memory.
    require(bool(rows), 'missing resource observations')
    warm = rows[min(2, len(rows)-1):]
    require(all(r['active'] == 1 and r['unexpected_errors'] == 0 for r in rows), 'cleanup or application errors')
    require(max(r['descriptors'] for r in warm) - min(r['descriptors'] for r in warm) <= 2, 'descriptor growth')
    require(max(r['live_words'] for r in warm) - min(r['live_words'] for r in warm) <= 131072, 'post-GC live heap growth exceeds 1 MiB')
    require(max(r['rss_kib'] for r in rows) <= 262144, 'process RSS exceeds 256 MiB personal-use budget')
    if len(warm) >= 8:
        n = max(2, len(warm)//4)
        growth = statistics.median(r['rss_kib'] for r in warm[-n:]) - statistics.median(r['rss_kib'] for r in warm[:n])
        require(growth <= 32768, ('post-warmup RSS growth exceeds 32 MiB', growth))


def graceful(port, process):
    # A slow active download must finish while admission is stopped; a partial
    # upload is then cancelled by the configured graceful deadline.
    s = socket.create_connection(('127.0.0.1', port), timeout=15)
    c = http.client.HTTPConnection('127.0.0.1', port, timeout=15)
    try:
        s.sendall(b'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nx')
        c.request('GET', '/download'); response = c.getresponse()
        first = response.read(8192)
        require(first == b'x'*8192, 'shutdown download prefix')
        start = time.monotonic()
        process.stdin.write(b'stop\n'); process.stdin.flush()
        size = len(first)
        while data := response.read(8192):
            require(data == b'x'*len(data), 'shutdown download corruption')
            size += len(data)
            time.sleep(.001)
        require(size == DOWNLOAD, 'shutdown truncated active download')
        c.close()
        process.wait(timeout=15)
        require(process.returncode == 0, ('shutdown failure', process.returncode))
        final = json.loads(process.stdout.read())
        require(final['active'] == 0 and final['opened'] == final['closed'], ('shutdown leaked', final))
        require(final['unexpected_errors'] == 0, ('shutdown unexpected errors', final))
        return dict(seconds=time.monotonic()-start, final=final)
    finally:
        s.close(); c.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['smoke','profile','soak'], default='smoke')
    parser.add_argument('--seconds', type=int)
    parser.add_argument('--epoch-seconds', type=int, default=60)
    parser.add_argument('--rate', type=float, default=20)
    parser.add_argument('--binary', type=Path)
    args = parser.parse_args()
    seconds = args.seconds if args.seconds is not None else {'smoke':3,'profile':10,'soak':7200}[args.mode]
    require(seconds > 0 and args.epoch_seconds > 0 and math.isfinite(args.rate) and args.rate > 0, 'positive duration and rate required')
    digest = source_hash()
    dune, env, _ = configuration()
    binary = args.binary or ROOT/f"_build-pkg-{env['HARNESS_COMPILER']}/default/examples/personal/eio_server.exe"
    if args.binary is None:
        subprocess.run(command(dune,env,['build','examples/personal/eio_server.exe']),cwd=ROOT,env=env,check=True)
    directory = ROOT/'_artifacts/personal'/f'{args.mode}-{time.time_ns()}'
    directory.mkdir(parents=True)
    result = dict(status='RUNNING', source_sha256=digest, mode=args.mode, seconds_requested=seconds,
                  directory=str(directory), epochs=[], observations=[])
    report = directory/'report.json'
    def save(): report.write_text(json.dumps(result,indent=2)+'\n')
    save()
    try:
        with server(binary,directory) as (port,p):
            result['adversarial_cases'] = adversarial(port)
            result['observations'].append(resources(port,p.pid))
            concurrency_levels = [1,4,8] if args.mode == 'profile' else [4]
            for concurrency in concurrency_levels:
                remaining = seconds
                while remaining > 0:
                    budget = min(args.epoch_seconds, remaining)
                    row = epoch(port,budget,concurrency,0 if args.mode=='profile' else args.rate,
                                42+100*len(result['epochs']))
                    result['epochs'].append(row)
                    result['observations'].append(resources(port,p.pid))
                    check_resources(result['observations'])
                    require(source_hash() == digest, 'sources changed during run')
                    save()
                    print(json.dumps(dict(mode=args.mode,completed_seconds=sum(r['seconds'] for r in result['epochs']),
                                          epoch=row,resources=result['observations'][-1])),flush=True)
                    remaining -= budget
            result['shutdown'] = graceful(port,p)
        result['status'] = 'PASS'
        result['timing_verdict'] = 'ADVISORY_LOCAL_HOST'
        result['limitations'] = ['Closed-loop Python client; latency buckets include intentional slow reads and reset operations.',
                                'Resource observations are quiescent between epochs; transient RSS is not sampled.',
                                'Personal-use evidence does not satisfy the public-release policy.']
        require(source_hash() == digest, 'sources changed during run')
        save()
        record('personal-'+args.mode+'.json', {k:v for k,v in result.items() if k != 'source_sha256'})
    except BaseException as exn:
        result['status']='FAIL'; result['error']=repr(exn); save(); raise
    print(json.dumps(dict(status='PASS',report=str(report))),flush=True)


if __name__ == '__main__':
    main()
