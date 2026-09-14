# Local protocol fixtures

`localhost.key` is a public, test-only RSA key generated for this fixture.
Never use it for a service. `localhost.pem` is its self-signed test certificate;
TLS validation uses a fixed 2026-09-14 clock so test results do not age out.
The certificate has DNS SAN `localhost`. Unknown roots and wrong hosts are rejected.
Key generation used the external OpenSSL executable, not local cryptographic code.

`payload.txt` contains 1024 repetitions of a fixed line. `payload.gz` was generated
by `gzip -n -c payload.txt`; it is an independent reference encoder fixture.
