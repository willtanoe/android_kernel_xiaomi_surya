#!/usr/bin/env python3

import subprocess
import sys
import unittest
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
FIXTURES = TEST_DIR / "fixtures" / "boot-artifacts"
VALIDATOR = TEST_DIR.parent / "validate-boot-artifacts.py"


def run_validator(args, check=True):
    cmd = [sys.executable, str(VALIDATOR)] + args
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise AssertionError(
            f"validator failed: {result.stderr}\ncommand: {' '.join(cmd)}"
        )
    return result


class BootArtifactValidationTest(unittest.TestCase):
    def test_accepts_valid_raw_artifacts(self):
        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
            ],
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_valid_zip(self):
        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
                "--zip", str(FIXTURES / "package.zip"),
                "--expected-zip-members",
                "kernels/Image.gz,kernels/dtb.img,kernels/dtbo.img,anykernel.sh",
            ],
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_empty_image(self):
        result = run_validator(
            [
                "--image", str(FIXTURES / "empty-Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty", result.stderr.lower())

    def test_rejects_mismatched_image_gz(self):
        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "bad-Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not decompress", result.stderr)

    def test_rejects_bad_dtb_magic(self):
        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "bad-magic.dtb"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("magic", result.stderr.lower())

    def test_rejects_dtbo_payload_out_of_range(self):
        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "bad-range.dtbo"),
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("out of range", result.stderr.lower())

    def test_rejects_zip_with_traversal(self):
        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
                "--zip", str(FIXTURES / "traversal.zip"),
                "--expected-zip-members",
                "kernels/Image.gz,kernels/dtb.img,kernels/dtbo.img,anykernel.sh",
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("traversal", result.stderr.lower())

    def test_rejects_zip_with_duplicate_members(self):
        # Build a zip with two identical names on the fly.
        import zipfile
        duplicate_zip = FIXTURES / "duplicate-built.zip"
        with zipfile.ZipFile(duplicate_zip, "w") as zf:
            zf.writestr("kernels/Image.gz", "first")
            zf.writestr("kernels/Image.gz", "second")

        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
                "--zip", str(duplicate_zip),
                "--expected-zip-members", "kernels/Image.gz",
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate", result.stderr.lower())

    def test_rejects_zip_with_missing_expected_members(self):
        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
                "--zip", str(FIXTURES / "package.zip"),
                "--expected-zip-members",
                "kernels/Image.gz,kernels/dtb.img,kernels/dtbo.img,anykernel.sh,missing.file",
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr.lower())

    def test_rejects_zip_with_mismatched_payload(self):
        # Build a zip containing a wrong Image.gz payload.
        import zipfile
        bad_payload_zip = FIXTURES / "bad-payload.zip"
        with zipfile.ZipFile(bad_payload_zip, "w") as zf:
            zf.writestr("kernels/Image.gz", b"wrong-payload")
            zf.writestr("kernels/dtb.img", (FIXTURES / "dtb.img").read_bytes())
            zf.writestr("kernels/dtbo.img", (FIXTURES / "dtbo.img").read_bytes())

        result = run_validator(
            [
                "--image", str(FIXTURES / "Image"),
                "--image-gz", str(FIXTURES / "Image.gz"),
                "--dtb", str(FIXTURES / "dtb.img"),
                "--dtbo", str(FIXTURES / "dtbo.img"),
                "--zip", str(bad_payload_zip),
                "--expected-zip-members",
                "kernels/Image.gz,kernels/dtb.img,kernels/dtbo.img",
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("payload mismatch", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
