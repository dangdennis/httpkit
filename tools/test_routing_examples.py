#!/usr/bin/env python3
"""Run the shared router/middleware application over both native loopback servers."""
from checks import require
import http.client
import selectors
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlsplit
from dune_env import ROOT, configuration, command

dune, env, _ = configuration()
subprocess.run(command(dune, env, ['build', './examples/routing/eio_server.exe',
                                 './examples/routing/lwt_server.exe']),
               cwd=ROOT, env=env, check=True, timeout=1800)
for runtime in ['eio', 'lwt']:
    with tempfile.TemporaryFile() as errors:
        binary = ROOT / ('_build-pkg-' + env['HARNESS_COMPILER']) / 'default/examples/routing' / (runtime + '_server.exe')
        server = subprocess.Popen([str(binary)], cwd=ROOT, env=env,
                                  stdout=subprocess.PIPE, stderr=errors)
        connection = None
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(server.stdout, selectors.EVENT_READ)
                require(ready.select(10), runtime + ' listener did not become ready')
            url = urlsplit(server.stdout.readline().decode().strip())
            require(url.scheme == 'http' and url.hostname == '127.0.0.1' and url.port, "test_routing_examples.py: url.scheme == 'http' and url.hostname == '127.0.0.1' and url.port")
            connection = http.client.HTTPConnection(url.hostname, url.port, timeout=5)
            # Reuse one connection to exercise response framing and retirement
            # as well as the route decisions and composed response metadata.
            cases = [
                ('GET', '/', None, 200, b'Hello /\n', None),
                ('GET', '/users/me', None, 200, b'Current user\n', None),
                ('GET', '/users/123?view=full', None, 200, b'User 123\n', None),
                ('GET', '/users/%2F', None, 200, b'User %2F\n', None),
                ('GET', '/files/a//b', None, 200, b'Raw path: a//b\n', None),
                ('GET', '/missing', None, 404, b'Not found\n', None),
                ('POST', '/users/123', b'', 405, b'Method not allowed\n', 'GET'),
                ('HEAD', '/users/123', None, 405, b'', 'GET'),
                ('POST', '/echo', b'body\x00bytes', 200, b'body\x00bytes', None),
                ('GET', '/', None, 200, b'Hello /\n', None),
            ]
            for method, target, body, status, expected, allow in cases:
                connection.request(method, target, body=body)
                response = connection.getresponse()
                actual = response.read()
                require((response.status, actual) == (status, expected), (runtime, method, target, response.status, actual))
                require(response.getheader('x-example') == 'http-kit', "test_routing_examples.py: response.getheader('x-example') == 'http-kit'")
                require(response.getheader('allow') == allow, "test_routing_examples.py: response.getheader('allow') == allow")
            print('PASS:', runtime, 'routing/middleware over persistent HTTP, including HEAD, 404/405 and raw captures')
        finally:
            if connection is not None:
                connection.close()
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait(timeout=5)
