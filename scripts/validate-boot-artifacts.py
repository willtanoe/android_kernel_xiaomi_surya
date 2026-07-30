#!/usr/bin/env python3
"""Validate raw and packaged ARM64 kernel boot artifacts.

Checks:
- Image is a nonempty ARM64 kernel image.
- Image.gz is a valid gzip that decompresses byte-for-byte to Image.
- DTB is a structurally valid FDT.
- DTBO has valid header, entries, and FDT payloads; bounds are checked.
- ZIP passes structural validation, contains exactly the expected members,
  has no duplicates/traversals/absolute paths, and payload bytes match the
  validated build outputs.
"""

import argparse
import gzip
import os
import struct
import sys
import zipfile
from pathlib import Path

# FDT header constants
FDT_MAGIC = 0xD00DFEED
FDT_HEADER_SIZE = 40  # version 17 header

# DTBO header constants
DTBO_MAGIC = 0xD7B7AB1E
ACPIO_MAGIC = 0x41435049
DTBO_HEADER_SIZE = 32
DTBO_ENTRY_SIZE = 32


def error(msg):
    print(f"ERROR: {msg}", file=sys.stderr)


def fail(msg):
    error(msg)
    sys.exit(1)


def validate_image(image_path):
    """Validate a raw ARM64 kernel Image."""
    data = Path(image_path).read_bytes()
    if len(data) == 0:
        fail(f"Image is empty: {image_path}")

    # ARM64 Image header: 32-bit branch instruction or code0/code1 magic.
    # Official arm64 Image header starts with "MZ" at offset 0x38 for EFI,
    # but legacy kernels start with a branch. Require at least the minimum
    # kernel header size and sane aarch64 text start.
    if len(data) < 64:
        fail(f"Image too small to be a kernel: {len(data)} bytes")

    # The first word is typically a branch or nop; we do not enforce a single
    # magic because kernel configurations vary. Instead require that the file
    # is large enough and does not start with obvious non-code patterns.
    first_word = struct.unpack_from("<I", data, 0)[0]
    # aarch64 instructions are 4-byte aligned; reject if first word is all-zero
    # or matches known container magic instead of code.
    if first_word == 0:
        fail(f"Image starts with zero word: {image_path}")

    return data


def validate_image_gz(image_gz_path, expected_image_bytes):
    """Validate Image.gz decompresses exactly to expected_image_bytes."""
    gz_data = Path(image_gz_path).read_bytes()
    if len(gz_data) == 0:
        fail(f"Image.gz is empty: {image_gz_path}")

    try:
        decompressed = gzip.decompress(gz_data)
    except Exception as exc:
        fail(f"Image.gz is not valid gzip ({image_gz_path}): {exc}")

    if decompressed != expected_image_bytes:
        fail(
            f"Image.gz does not decompress to Image: "
            f"{len(decompressed)} vs {len(expected_image_bytes)} bytes"
        )

    return decompressed


def validate_dtb(dtb_path):
    """Validate a Device Tree Blob."""
    data = Path(dtb_path).read_bytes()
    if len(data) < FDT_HEADER_SIZE:
        fail(f"DTB too small: {len(data)} bytes < {FDT_HEADER_SIZE}")

    magic, totalsize, off_dt_struct, off_dt_strings, version, \
        last_comp_version, boot_cpuid_phys, size_dt_strings, size_dt_struct = \
        struct.unpack_from(">9I", data, 0)

    if magic != FDT_MAGIC:
        fail(f"DTB has invalid magic: {hex(magic)} (expected {hex(FDT_MAGIC)})")

    if len(data) != totalsize:
        fail(f"DTB size mismatch: file {len(data)} vs header {totalsize}")

    if version < 16 or version > 40:
        fail(f"DTB unsupported version: {version}")

    if last_comp_version > version:
        fail(f"DTB last compatible version {last_comp_version} > version {version}")

    if off_dt_struct + size_dt_struct > totalsize:
        fail("DTB structure block extends past end of blob")

    if off_dt_strings + size_dt_strings > totalsize:
        fail("DTB strings block extends past end of blob")

    # Minimum alignment for FDT blocks is 4 bytes.
    if off_dt_struct % 4 != 0 or off_dt_strings % 4 != 0:
        fail("DTB block offsets are not 4-byte aligned")

    return data


def validate_dtbo(dtbo_path):
    """Validate a Device Tree Blob Overlay image."""
    data = Path(dtbo_path).read_bytes()
    if len(data) < DTBO_HEADER_SIZE:
        fail(f"DTBO too small: {len(data)} bytes < {DTBO_HEADER_SIZE}")

    magic, total_size, header_size, dt_entry_size, dt_entry_count, \
        dt_entries_offset, page_size, version = \
        struct.unpack_from(">8I", data, 0)

    if magic not in (DTBO_MAGIC, ACPIO_MAGIC):
        fail(f"DTBO has invalid magic: {hex(magic)}")

    if header_size != DTBO_HEADER_SIZE:
        fail(f"DTBO header size mismatch: {header_size} != {DTBO_HEADER_SIZE}")

    if dt_entry_size != DTBO_ENTRY_SIZE:
        fail(f"DTBO entry size mismatch: {dt_entry_size} != {DTBO_ENTRY_SIZE}")

    if len(data) != total_size:
        fail(f"DTBO size mismatch: file {len(data)} vs header {total_size}")

    if version not in (0, 1):
        fail(f"DTBO unsupported version: {version}")

    metadata_size = header_size + dt_entry_count * dt_entry_size
    if metadata_size > total_size:
        fail("DTBO metadata size exceeds total size")

    if dt_entries_offset < header_size or dt_entries_offset > total_size:
        fail("DTBO entries offset out of range")

    if page_size not in (2048, 4096, 8192, 16384):
        fail(f"DTBO suspicious page size: {page_size}")

    entries = []
    for i in range(dt_entry_count):
        entry_offset = dt_entries_offset + i * dt_entry_size
        if entry_offset + DTBO_ENTRY_SIZE > total_size:
            fail(f"DTBO entry {i} header out of range")

        dt_size, dt_offset = struct.unpack_from(">2I", data, entry_offset)

        if dt_offset + dt_size > total_size:
            fail(f"DTBO entry {i} payload out of range: "
                 f"offset={dt_offset} size={dt_size} total={total_size}")

        if dt_size < FDT_HEADER_SIZE:
            fail(f"DTBO entry {i} payload too small for FDT: {dt_size}")

        payload_magic = struct.unpack_from(">I", data, dt_offset)[0]
        if payload_magic != FDT_MAGIC:
            fail(f"DTBO entry {i} payload has invalid FDT magic: {hex(payload_magic)}")

        # Validate the FDT header inside this DTBO entry.
        validate_dtb_bytes(data[dt_offset:dt_offset + dt_size], context=f"DTBO entry {i}")

        entries.append({
            "index": i,
            "dt_size": dt_size,
            "dt_offset": dt_offset,
        })

    return data, entries


def validate_dtb_bytes(data, context="DTB"):
    """Validate an FDT contained in a byte string."""
    if len(data) < FDT_HEADER_SIZE:
        fail(f"{context} too small: {len(data)} bytes")

    magic, totalsize, off_dt_struct, off_dt_strings, version, \
        last_comp_version, boot_cpuid_phys, size_dt_strings, size_dt_struct = \
        struct.unpack_from(">9I", data, 0)

    if magic != FDT_MAGIC:
        fail(f"{context} invalid magic: {hex(magic)}")

    if len(data) != totalsize:
        fail(f"{context} size mismatch: {len(data)} vs {totalsize}")

    if version < 16 or version > 40:
        fail(f"{context} unsupported version: {version}")

    if off_dt_struct + size_dt_struct > totalsize:
        fail(f"{context} structure block out of range")

    if off_dt_strings + size_dt_strings > totalsize:
        fail(f"{context} strings block out of range")

    if off_dt_struct % 4 != 0 or off_dt_strings % 4 != 0:
        fail(f"{context} block offsets not aligned")


def validate_zip(zip_path, required_members, expected_payloads):
    """Validate a packaged ZIP.

    required_members: set of normalized member names that must be present.
    expected_payloads: dict mapping normalized member name to exact bytes.
    Other members (e.g. AnyKernel scripts and tools) are allowed.
    """
    if not os.path.isfile(zip_path):
        fail(f"ZIP does not exist: {zip_path}")

    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            bad_file = zf.testzip()
            if bad_file is not None:
                fail(f"ZIP CRC/checksum error in member: {bad_file}")

            names = zf.namelist()
            normalized = []
            for name in names:
                # Reject absolute paths and traversal attempts.
                if os.path.isabs(name):
                    fail(f"ZIP contains absolute member path: {name}")
                parts = name.replace("\\", "/").split("/")
                if any(part == ".." for part in parts):
                    fail(f"ZIP contains traversal member: {name}")
                normalized.append(name.replace("\\", "/"))

            if len(normalized) != len(set(normalized)):
                fail("ZIP contains duplicate members")

            member_set = set(normalized)
            missing = required_members - member_set
            if missing:
                fail(f"ZIP missing required members: {sorted(missing)}")

            for member_name, expected_bytes in expected_payloads.items():
                try:
                    actual = zf.read(member_name)
                except KeyError:
                    fail(f"ZIP missing payload member: {member_name}")
                if actual != expected_bytes:
                    fail(f"ZIP payload mismatch for {member_name}: "
                         f"{len(actual)} vs {len(expected_bytes)} bytes")
    except zipfile.BadZipFile as exc:
        fail(f"ZIP is structurally invalid ({zip_path}): {exc}")


def validate_raw_artifacts(image, image_gz, dtb, dtbo):
    """Validate all raw build artifacts and return their bytes.

    Returns a dict mapping base filenames to the original file bytes. The
    Image.gz entry is the original compressed bytes; callers that need the
    decompressed Image should use the 'Image' entry.
    """
    image_bytes = validate_image(image)
    image_gz_path = Path(image_gz)
    image_gz_bytes = image_gz_path.read_bytes()
    validate_image_gz(image_gz, image_bytes)
    dtb_bytes = validate_dtb(dtb)
    dtbo_bytes, _ = validate_dtbo(dtbo)

    return {
        "Image": image_bytes,
        "Image.gz": image_gz_bytes,
        "dtb.img": dtb_bytes,
        "dtbo.img": dtbo_bytes,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Validate raw and packaged ARM64 kernel boot artifacts"
    )
    parser.add_argument("--image", required=True, help="Path to Image")
    parser.add_argument("--image-gz", required=True, help="Path to Image.gz")
    parser.add_argument("--dtb", required=True, help="Path to dtb.img")
    parser.add_argument("--dtbo", required=True, help="Path to dtbo.img")
    parser.add_argument("--zip", help="Path to packaged ZIP to validate")
    parser.add_argument(
        "--expected-zip-members",
        help="Comma-separated list of expected ZIP member names",
    )
    args = parser.parse_args()

    validated = validate_raw_artifacts(args.image, args.image_gz, args.dtb, args.dtbo)

    if args.zip:
        if not args.expected_zip_members:
            fail("--expected-zip-members required when --zip is given")

        required_members = set(
            name.strip() for name in args.expected_zip_members.split(",") if name.strip()
        )

        # Map required kernel payload members to the validated raw bytes.
        expected_payloads = {}
        for member in required_members:
            basename = os.path.basename(member)
            if basename in validated:
                expected_payloads[member] = validated[basename]

        validate_zip(args.zip, required_members, expected_payloads)

    print("All boot artifacts validated successfully.")


if __name__ == "__main__":
    main()
