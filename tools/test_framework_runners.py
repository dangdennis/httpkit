#!/usr/bin/env python3
"""Failure controls for disposable validation processes."""

import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_framework import Application
from test_framework_databases import Postgres


class RunnerCleanup(unittest.TestCase):
    def test_invalid_start_reaps_application(self):
        with tempfile.TemporaryDirectory(prefix="framework-start-") as temporary:
            root = Path(temporary)
            executable = root / "invalid-server"
            executable.write_text(
                "#!/bin/sh\necho $$ > '" + str(root / "pid") + "'\n"
                "echo INVALID\nexec sleep 60\n"
            )
            executable.chmod(0o700)
            with self.assertRaises(Exception):
                Application(executable, root)
            with self.assertRaises(ProcessLookupError):
                os.kill(int((root / "pid").read_text()), 0)

    def test_failed_postgres_start_stops_owned_server(self):
        with tempfile.TemporaryDirectory(prefix="framework-postgres-") as temporary:
            # This exceeds macOS's socket-path limit; the runner must use TCP.
            server = Postgres(Path(temporary) / ("deep-artifact-" * 8))
            run = server.run

            def fail_after_start(name, command):
                run(name, command)
                if name == "start":
                    raise RuntimeError("injected failure after startup")

            with patch.object(server, "run", side_effect=fail_after_start):
                with self.assertRaisesRegex(RuntimeError, "injected failure"):
                    server.__enter__()
            self.assertFalse((server.data / "postmaster.pid").exists())
            self.assertTrue((server.directory / "stop.log").exists())


if __name__ == "__main__":
    unittest.main()
