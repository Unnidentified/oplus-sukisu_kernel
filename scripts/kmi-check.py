#!/usr/bin/env python3
"""Compare a built kernel's exported symbols against the GKI ABI (abi.stg).

The GKI ABI is tracked in gki/aarch64/abi.stg as a symbol type graph. Each
elf_symbol block carries the symbol name, whether it is defined, and the
genksyms CRC of its type signature. Module.symvers carries the same CRC for
every symbol the build exports.

A symbol that disappears, or whose CRC changes, is an ABI break: a vendor module
built against the stock kernel will refuse to load. This script reports both.

Usage:
    kmi-check.py --stg gki/aarch64/abi.stg --symvers out/Module.symvers
                 [--report kmi-report.txt] [--strict]

Exit codes: 0 clean (or non-strict with findings), 1 findings under --strict,
2 unusable input.
"""

from __future__ import annotations

import argparse
import re
import sys

SYMBOL_BLOCK = re.compile(r"^elf_symbol \{\n(.*?)^\}", re.M | re.S)
FIELD = re.compile(r"^\s+(\w+): (.+)$", re.M)


def parse_stg(path: str) -> dict[str, int]:
    """Return {symbol: crc} for every defined symbol in the ABI."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    symbols: dict[str, int] = {}
    for match in SYMBOL_BLOCK.finditer(text):
        fields = dict(FIELD.findall(match.group(1)))
        if fields.get("is_defined", "").strip() != "true":
            continue
        name = fields.get("name", "").strip().strip('"')
        crc = fields.get("crc", "").strip()
        if not name or not crc.startswith("0x"):
            continue
        symbols[name] = int(crc, 16)
    return symbols


def parse_symvers(path: str) -> dict[str, int]:
    """Return {symbol: crc} from a Module.symvers file."""
    symbols: dict[str, int] = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2 or not parts[0].startswith("0x"):
                continue
            try:
                symbols[parts[1]] = int(parts[0], 16)
            except ValueError:
                continue
    return symbols


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stg", required=True)
    ap.add_argument("--symvers", required=True)
    ap.add_argument("--report")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    try:
        abi = parse_stg(args.stg)
        built = parse_symvers(args.symvers)
    except OSError as exc:
        print(f"kmi-check: {exc}", file=sys.stderr)
        return 2

    if not abi:
        print(f"kmi-check: no symbols parsed from {args.stg}", file=sys.stderr)
        return 2
    if not built:
        print(f"kmi-check: no symbols parsed from {args.symvers}", file=sys.stderr)
        return 2

    missing = sorted(name for name in abi if name not in built)
    changed = sorted(
        (name, abi[name], built[name])
        for name in abi
        if name in built and built[name] != abi[name]
    )

    lines = [
        f"ABI symbols: {len(abi)}",
        f"Exported symbols: {len(built)}",
        f"Missing: {len(missing)}",
        f"CRC changed: {len(changed)}",
    ]
    if missing:
        lines.append("")
        lines.append("Missing symbols:")
        lines.extend(f"  {name}" for name in missing)
    if changed:
        lines.append("")
        lines.append("CRC changed (ABI break):")
        lines.extend(
            f"  {name}: abi 0x{want:08x} != built 0x{got:08x}"
            for name, want, got in changed
        )

    report = "\n".join(lines) + "\n"
    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            fh.write(report)

    findings = len(missing) + len(changed)
    if findings:
        print(report, file=sys.stderr)
        if args.strict:
            print(f"::error::KMI check failed: {findings} finding(s)", file=sys.stderr)
            return 1
        print(f"::warning::KMI check: {findings} finding(s), not fatal", file=sys.stderr)
        return 0

    print(f"KMI check clean ({len(abi)} symbols)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
