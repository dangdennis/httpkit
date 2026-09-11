"""Operational requirements stay active under Python optimization."""


def require(condition, detail):
    if not condition:
        raise RuntimeError(detail)


MUTANTS = {'framing-cl-te', 'foreign-request-id', 'output-accounting'}
INTEROP_LANES = {
    runtime + '/' + lane
    for runtime in ('eio', 'lwt')
    for lane in ('direct', 'nginx-buffering-on', 'nginx-buffering-off')
}


def has_inventory(rows, key, expected):
    """Reject malformed, missing and duplicate identities, even at equal counts."""
    return (isinstance(rows, list) and len(rows) == len(expected)
            and all(isinstance(row, dict) and isinstance(row.get(key), str)
                    for row in rows)
            and {row[key] for row in rows} == expected)
