# Local protocol fixtures

`localhost.key` is a public, test-only RSA key generated for this fixture.
Never use it for a service. `localhost.pem` is its self-signed test certificate;
TLS validation uses a fixed 2026-09-14 clock so test results do not age out.
The certificate has DNS SAN `localhost`. Unknown roots and wrong hosts are rejected.
Key generation used the external OpenSSL executable, not local cryptographic code.

`payload.txt` contains 1024 repetitions of a fixed line. `payload.gz` was generated
by `gzip -n -c payload.txt`; it is an independent reference encoder fixture.

`loopback.pem` uses the same public test key and adds IP SAN `127.0.0.1`.
Client lifecycle fixtures connect to that literal address: resolving `localhost`
can select an unrelated IPv6 listener sharing the IPv4 fixture's ephemeral port.
The DNS-only certificate remains in use for wrong-host rejection tests. The IP
certificate was signed with OpenSSL, SHA-256, and fixed validity from
2026-09-14 to 2036-09-10; client tests use a fixed 2026-09-16 clock.
