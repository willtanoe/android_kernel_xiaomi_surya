#!/usr/bin/env python3

import gzip
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
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
    @classmethod
    def setUpClass(cls):
        cls.temp_dir = tempfile.TemporaryDirectory()
        cls.fixtures = Path(cls.temp_dir.name)

        image = struct.pack("<I", 0x14000000) + bytes(60)
        fdt = struct.pack(
            ">10I",
            0xD00DFEED, 40, 40, 40, 17, 16, 0, 0, 0, 0,
        )
        dtbo_header = struct.pack(
            ">8I", 0xD7B7AB1E, 104, 32, 32, 1, 32, 4096, 0,
        )
        dtbo_entry = struct.pack(">8I", 40, 64, 0, 0, 0, 0, 0, 0)
        dtbo = dtbo_header + dtbo_entry + fdt
        bad_range_header = struct.pack(
            ">8I", 0xD7B7AB1E, 64, 32, 32, 1, 32, 4096, 0,
        )
        bad_range_entry = struct.pack(">8I", 40, 64, 0, 0, 0, 0, 0, 0)

        artifacts = {
            "Image": image,
            "Image.gz": gzip.compress(image, mtime=0),
            "bad-Image.gz": gzip.compress(image + b"bad", mtime=0),
            "dtb.img": fdt,
            "bad-magic.dtb": bytes(40),
            "dtbo.img": dtbo,
            "bad-range.dtbo": bad_range_header + bad_range_entry,
            "empty-Image": b"",
        }
        for name, data in artifacts.items():
            (cls.fixtures / name).write_bytes(data)

        with zipfile.ZipFile(cls.fixtures / "package.zip", "w") as zf:
            zf.writestr("kernels/Image.gz", artifacts["Image.gz"])
            zf.writestr("kernels/dtb.img", fdt)
            zf.writestr("kernels/dtbo.img", dtbo)
            zf.writestr("anykernel.sh", "#!/sbin/sh\n")

        with zipfile.ZipFile(cls.fixtures / "traversal.zip", "w") as zf:
            zf.writestr("../escape", "unsafe")

    @classmethod
    def tearDownClass(cls):
        cls.temp_dir.cleanup()

    def test_accepts_valid_raw_artifacts(self):
        result = run_validator(
            [
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
            ],
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_valid_zip(self):
        result = run_validator(
            [
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
                "--zip", str(self.fixtures / "package.zip"),
                "--expected-zip-members",
                "kernels/Image.gz,kernels/dtb.img,kernels/dtbo.img,anykernel.sh",
            ],
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_empty_image(self):
        result = run_validator(
            [
                "--image", str(self.fixtures / "empty-Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty", result.stderr.lower())

    def test_rejects_mismatched_image_gz(self):
        result = run_validator(
            [
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "bad-Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not decompress", result.stderr)

    def test_rejects_bad_dtb_magic(self):
        result = run_validator(
            [
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "bad-magic.dtb"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("magic", result.stderr.lower())

    def test_rejects_dtbo_payload_out_of_range(self):
        result = run_validator(
            [
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "bad-range.dtbo"),
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("out of range", result.stderr.lower())

    def test_rejects_zip_with_traversal(self):
        result = run_validator(
            [
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
                "--zip", str(self.fixtures / "traversal.zip"),
                "--expected-zip-members",
                "kernels/Image.gz,kernels/dtb.img,kernels/dtbo.img,anykernel.sh",
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("traversal", result.stderr.lower())

    def test_rejects_zip_with_duplicate_members(self):
        duplicate_zip = self.fixtures / "duplicate-built.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(duplicate_zip, "w") as zf:
                zf.writestr("kernels/Image.gz", "first")
                zf.writestr("kernels/Image.gz", "second")

        result = run_validator(
            [
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
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
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
                "--zip", str(self.fixtures / "package.zip"),
                "--expected-zip-members",
                "kernels/Image.gz,kernels/dtb.img,kernels/dtbo.img,anykernel.sh,missing.file",
            ],
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr.lower())

    def test_rejects_zip_with_mismatched_payload(self):
        bad_payload_zip = self.fixtures / "bad-payload.zip"
        with zipfile.ZipFile(bad_payload_zip, "w") as zf:
            zf.writestr("kernels/Image.gz", b"wrong-payload")
            zf.writestr("kernels/dtb.img", (self.fixtures / "dtb.img").read_bytes())
            zf.writestr("kernels/dtbo.img", (self.fixtures / "dtbo.img").read_bytes())

        result = run_validator(
            [
                "--image", str(self.fixtures / "Image"),
                "--image-gz", str(self.fixtures / "Image.gz"),
                "--dtb", str(self.fixtures / "dtb.img"),
                "--dtbo", str(self.fixtures / "dtbo.img"),
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
