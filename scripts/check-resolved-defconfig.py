#!/usr/bin/env python3

import argparse
import ast
import re
import sys
from pathlib import Path


ASSIGNMENT_RE = re.compile(r"^(CONFIG_[A-Z0-9_]+)=(.*)$")
DISABLED_RE = re.compile(r"^# (CONFIG_[A-Z0-9_]+) is not set$")
NUMBER_RE = re.compile(r"^-?(?:0[xX][0-9a-fA-F]+|[0-9]+)$")

NOKSU_HIDDEN_SETTINGS = frozenset(
    {
        "CONFIG_KSU_DEBUG",
        "CONFIG_KSU_LSM_SECURITY_HOOKS",
        "CONFIG_KSU_TAMPER_SYSCALL_TABLE",
        "CONFIG_KSU_THRONE_TRACKER_ALWAYS_THREADED",
    }
)


class ConfigValue:
    def __init__(self, raw):
        self.raw = raw
        self.normalized = self._normalize(raw)

    @staticmethod
    def _normalize(raw):
        if raw in {"y", "m", "n"}:
            return ("tristate", raw)
        if raw.startswith('"') and raw.endswith('"'):
            value = ast.literal_eval(raw)
            if not isinstance(value, str):
                raise ValueError("quoted configuration value is not a string")
            return ("string", value)
        if NUMBER_RE.fullmatch(raw):
            base = 16 if raw.lower().lstrip("-").startswith("0x") else 10
            return ("number", int(raw, base))
        return ("raw", raw)

    def __eq__(self, other):
        return self.normalized == other.normalized


def parse_config(path):
    settings = {}

    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ValueError("cannot read {}: {}".format(path, error)) from error

    for line_number, line in enumerate(lines, start=1):
        disabled = DISABLED_RE.fullmatch(line)
        assignment = ASSIGNMENT_RE.fullmatch(line)
        if disabled:
            name = disabled.group(1)
            value = ConfigValue("n")
        elif assignment:
            name = assignment.group(1)
            try:
                value = ConfigValue(assignment.group(2))
            except (SyntaxError, ValueError) as error:
                raise ValueError(
                    "{}:{}: invalid value for {}: {}".format(
                        path, line_number, name, error
                    )
                ) from error
        else:
            continue

        if name in settings:
            raise ValueError(
                "{}:{}: duplicate request for {}".format(path, line_number, name)
            )
        settings[name] = value

    return settings


def find_mismatches(requested, resolved, variant):
    mismatches = []

    for name in sorted(requested):
        expected = requested[name]

        if variant == "NoKSU" and name == "CONFIG_KSU":
            expected = ConfigValue("n")

        actual = resolved.get(name)
        if actual is None:
            if variant == "NoKSU" and name in NOKSU_HIDDEN_SETTINGS:
                continue
            mismatches.append(
                "{} requested as {} but disappeared after resolution".format(
                    name, expected.raw
                )
            )
        elif expected != actual:
            mismatches.append(
                "{} requested as {} but resolved to {}".format(
                    name, expected.raw, actual.raw
                )
            )

    return mismatches


def main():
    parser = argparse.ArgumentParser(
        description="Verify that defconfig requests survive Kconfig resolution"
    )
    parser.add_argument("defconfig", type=Path)
    parser.add_argument("resolved_config", type=Path)
    parser.add_argument("--variant", choices=("KSU", "NoKSU"), required=True)
    args = parser.parse_args()

    try:
        requested = parse_config(args.defconfig)
        resolved = parse_config(args.resolved_config)
    except ValueError as error:
        print("error: {}".format(error), file=sys.stderr)
        return 2

    mismatches = find_mismatches(requested, resolved, args.variant)
    if mismatches:
        for mismatch in mismatches:
            print("error: {}".format(mismatch), file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
