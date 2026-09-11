"""Exercise actual evidence guards without running compilers or AFL campaigns."""

import ast
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest

from checks import require, has_inventory, MUTANTS


class OperationalChecks(unittest.TestCase):
    def test_production_guards(self):
        root = Path(__file__).parent
        fixtures = {
            "mutations.py": [
                (
                    "baseline.returncode",
                    dict(
                        baseline=SimpleNamespace(returncode=1, stdout=b"", stderr=b"")
                    ),
                ),
                ("original.count", dict(original="", before="missing", name="drift")),
                (
                    "result.returncode",
                    dict(
                        result=SimpleNamespace(returncode=0, stdout=b"", stderr=b""),
                        name="survivor",
                    ),
                ),
                ("source_hash()", dict(source_hash=lambda: "new", digest="old")),
            ],
            "campaign.py": [
                (
                    "result.returncode",
                    dict(
                        result=SimpleNamespace(returncode=1),
                        name="test",
                        directory="logs",
                    ),
                ),
                ("not findings", dict(findings=["finding"], name="test")),
                (
                    "seconds>=",
                    dict(
                        seconds=1,
                        executions=100,
                        args=SimpleNamespace(seconds=30),
                        name="test",
                        stats={},
                    ),
                ),
                (
                    "seconds>=",
                    dict(
                        seconds=30,
                        executions=0,
                        args=SimpleNamespace(seconds=30),
                        name="test",
                        stats={},
                    ),
                ),
            ],
        }
        for filename, cases in fixtures.items():
            source = (root / filename).read_text()
            calls = [
                node
                for node in ast.walk(ast.parse(source))
                if isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "require"
            ]
            for fragment, values in cases:
                call = next(
                    node
                    for node in calls
                    if "".join(fragment.split())
                    in "".join(ast.get_source_segment(source, node.args[0]).split())
                )
                for optimization in (0, 1, 2):
                    with self.subTest(
                        file=filename, guard=fragment, optimization=optimization
                    ):
                        code = compile(
                            ast.Expression(call),
                            filename,
                            "eval",
                            optimize=optimization,
                        )
                        with self.assertRaises(RuntimeError):
                            eval(code, dict(require=require, **values))

    def test_inventory(self):
        rows = [{"name": name} for name in MUTANTS]
        self.assertTrue(has_inventory(rows, "name", MUTANTS))
        for invalid in (None, rows[:-1], rows + rows[:1], [rows[0]] * 3, [{}, {}, {}]):
            self.assertFalse(has_inventory(invalid, "name", MUTANTS))

    def test_subprocess_optimization(self):
        code = "from checks import require; require(False, 'surviving mutant')"
        for flags, extra in (([], {}), (["-O"], {}), ([], {"PYTHONOPTIMIZE": "1"})):
            result = subprocess.run(
                [sys.executable, *flags, "-c", code],
                cwd=Path(__file__).parent,
                env={**os.environ, **extra},
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("surviving mutant", result.stderr)

    def test_no_removable_operational_checks(self):
        for path in Path(__file__).parent.glob("*.py"):
            self.assertFalse(
                any(
                    isinstance(node, ast.Assert)
                    for node in ast.walk(ast.parse(path.read_text()))
                ),
                path,
            )


if __name__ == "__main__":
    unittest.main()
