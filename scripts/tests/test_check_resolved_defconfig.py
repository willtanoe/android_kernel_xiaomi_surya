#!/usr/bin/env python3

import subprocess
import sys
import unittest
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
FIXTURES = TEST_DIR / "fixtures" / "resolved-defconfig"
CHECKER = TEST_DIR.parent / "check-resolved-defconfig.py"


class ResolvedDefconfigTest(unittest.TestCase):
    def run_checker(self, requested, resolved, variant="KSU"):
        return subprocess.run(
            [
                sys.executable,
                str(CHECKER),
                str(FIXTURES / requested),
                str(FIXTURES / resolved),
                "--variant",
                variant,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_preserved_value_types(self):
        result = self.run_checker("types.defconfig", "types.config")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reports_disappeared_requests(self):
        result = self.run_checker("types.defconfig", "missing.config")

        self.assertEqual(result.returncode, 1)
        self.assertIn("CONFIG_COUNT", result.stderr)
        self.assertIn("disappeared", result.stderr)

    def test_reports_changed_requests(self):
        result = self.run_checker("types.defconfig", "changed.config")

        self.assertEqual(result.returncode, 1)
        self.assertIn("CONFIG_ENABLED", result.stderr)
        self.assertIn("CONFIG_LABEL", result.stderr)
        self.assertIn("CONFIG_MASK", result.stderr)
        self.assertIn("CONFIG_WORD", result.stderr)

    def test_allows_explicit_noksu_resolution(self):
        result = self.run_checker(
            "ksu.defconfig", "noksu.config", variant="NoKSU"
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_noksu_still_requires_unrelated_settings(self):
        result = self.run_checker(
            "ksu.defconfig", "noksu-missing.config", variant="NoKSU"
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("CONFIG_REQUIRED", result.stderr)

    def test_ksu_requires_its_dependent_settings(self):
        result = self.run_checker("ksu.defconfig", "noksu.config")

        self.assertEqual(result.returncode, 1)
        self.assertIn("CONFIG_KSU", result.stderr)
        self.assertIn("CONFIG_KSU_TAMPER_SYSCALL_TABLE", result.stderr)


if __name__ == "__main__":
    unittest.main()
